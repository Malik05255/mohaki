#include "DeviceMaintenance.hpp"

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace jawal {
namespace {

bool RunHiddenAndWait(const std::wstring& command, const std::filesystem::path& cwd) {
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, mutableCommand.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                        nullptr, cwd.c_str(), &startup, &process)) {
        return false;
    }

    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    return exitCode == 0;
}

std::wstring Quote(const std::filesystem::path& value) {
    return L"\"" + value.wstring() + L"\"";
}

std::filesystem::path QemuImg(const std::filesystem::path& runtimeDir) {
    return runtimeDir / L"qemu" / L"qemu-img.exe";
}

bool CheckImage(const std::filesystem::path& runtimeDir, const std::filesystem::path& image) {
    const auto qemuImg = QemuImg(runtimeDir);
    if (!std::filesystem::exists(qemuImg) || !std::filesystem::exists(image)) return false;
    return RunHiddenAndWait(Quote(qemuImg) + L" check " + Quote(image), runtimeDir);
}

bool ConvertImage(const std::filesystem::path& runtimeDir,
                  const std::filesystem::path& source,
                  const std::filesystem::path& destination,
                  bool compress) {
    const auto qemuImg = QemuImg(runtimeDir);
    if (!std::filesystem::exists(qemuImg) || !std::filesystem::exists(source)) return false;
    std::wstring command = Quote(qemuImg) + L" convert -O qcow2 ";
    if (compress) command += L"-c ";
    command += Quote(source) + L" " + Quote(destination);
    return RunHiddenAndWait(command, runtimeDir);
}

void MarkStandaloneData(const std::filesystem::path& dataDirectory) {
    const auto marker = dataDirectory / L"data-independent-v1.marker";
    std::ofstream output(marker, std::ios::trunc);
    if (output) output << "standalone-qcow2-v1\n";
    output.close();

    std::error_code ec;
    std::filesystem::remove(dataDirectory / L"data.qcow2.creating", ec);
    ec.clear();
    std::filesystem::remove(dataDirectory / L"data.qcow2.pre-standalone", ec);
}

std::filesystem::path TimestampedBackup(const std::filesystem::path& backupDir) {
    SYSTEMTIME t{};
    GetLocalTime(&t);
    wchar_t name[128]{};
    swprintf_s(name, L"jawal-%04u%02u%02u-%02u%02u%02u.qcow2",
               t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    return backupDir / name;
}

std::filesystem::path LatestBackup(const std::filesystem::path& backupDir) {
    std::filesystem::path latest;
    std::filesystem::file_time_type latestTime{};
    std::error_code ec;
    if (!std::filesystem::exists(backupDir, ec)) return {};

    for (const auto& entry : std::filesystem::directory_iterator(backupDir, ec)) {
        if (ec) break;
        if (!entry.is_regular_file()) continue;
        const auto path = entry.path();
        if (_wcsicmp(path.extension().c_str(), L".qcow2") != 0) continue;
        const auto time = entry.last_write_time(ec);
        if (ec) { ec.clear(); continue; }
        if (latest.empty() || time > latestTime) {
            latest = path;
            latestTime = time;
        }
    }
    return latest;
}

bool AtomicReplace(const std::filesystem::path& replacement,
                   const std::filesystem::path& target,
                   std::wstring* error) {
    const auto previous = target.parent_path() / L"data.previous.qcow2";
    std::error_code ec;
    std::filesystem::remove(previous, ec);
    ec.clear();

    if (std::filesystem::exists(target)) {
        std::filesystem::rename(target, previous, ec);
        if (ec) {
            if (error) *error = L"تعذر حفظ نسخة الأمان المؤقتة من بيانات الجوال.";
            return false;
        }
    }

    ec.clear();
    std::filesystem::rename(replacement, target, ec);
    if (ec) {
        std::error_code rollback;
        if (std::filesystem::exists(previous)) std::filesystem::rename(previous, target, rollback);
        if (error) *error = L"تعذر استبدال قرص بيانات الجوال.";
        return false;
    }

    std::filesystem::remove(previous, ec);
    return true;
}

} // namespace

MaintenanceResult CreateDataBackup(const std::filesystem::path& runtimeDir,
                                   const std::filesystem::path& dataDirectory) {
    MaintenanceResult result{};
    const auto data = dataDirectory / L"data.qcow2";
    const auto backupDir = dataDirectory / L"backups";
    std::error_code ec;
    std::filesystem::create_directories(backupDir, ec);

    if (!CheckImage(runtimeDir, data)) {
        result.detail = L"فشل فحص سلامة بيانات الجوال؛ لم يتم إنشاء النسخة الاحتياطية.";
        return result;
    }

    const auto backup = TimestampedBackup(backupDir);
    if (!ConvertImage(runtimeDir, data, backup, true) || !CheckImage(runtimeDir, backup)) {
        std::filesystem::remove(backup, ec);
        result.detail = L"تعذر إنشاء نسخة احتياطية سليمة.";
        return result;
    }

    result.ok = true;
    result.artifact = backup;
    result.detail = L"تم إنشاء نسخة احتياطية مضغوطة بنجاح.";
    return result;
}

MaintenanceResult RestoreLatestDataBackup(const std::filesystem::path& runtimeDir,
                                          const std::filesystem::path& dataDirectory) {
    MaintenanceResult result{};
    const auto backup = LatestBackup(dataDirectory / L"backups");
    if (backup.empty()) {
        result.detail = L"لا توجد نسخة احتياطية سابقة للاستعادة.";
        return result;
    }
    if (!CheckImage(runtimeDir, backup)) {
        result.detail = L"آخر نسخة احتياطية تالفة أو غير قابلة للقراءة.";
        return result;
    }

    const auto target = dataDirectory / L"data.qcow2";
    const auto temporary = dataDirectory / L"data.restore.tmp.qcow2";
    std::error_code ec;
    std::filesystem::remove(temporary, ec);

    // qemu-img convert always materializes a self-contained destination, even
    // if a historical backup originated from an old backing-file data chain.
    if (!ConvertImage(runtimeDir, backup, temporary, false) || !CheckImage(runtimeDir, temporary)) {
        std::filesystem::remove(temporary, ec);
        result.detail = L"تعذر تجهيز بيانات النسخة الاحتياطية للاستعادة.";
        return result;
    }

    std::wstring replaceError;
    if (!AtomicReplace(temporary, target, &replaceError)) {
        std::filesystem::remove(temporary, ec);
        result.detail = replaceError;
        return result;
    }
    MarkStandaloneData(dataDirectory);

    result.ok = true;
    result.artifact = backup;
    result.detail = L"تمت استعادة آخر نسخة احتياطية بنجاح.";
    return result;
}

MaintenanceResult CheckAndCompactData(const std::filesystem::path& runtimeDir,
                                      const std::filesystem::path& dataDirectory) {
    MaintenanceResult result{};
    const auto target = dataDirectory / L"data.qcow2";
    if (!CheckImage(runtimeDir, target)) {
        result.detail = L"فشل فحص قرص البيانات؛ تم إيقاف الصيانة لحماية بياناتك.";
        return result;
    }

    const auto temporary = dataDirectory / L"data.compact.tmp.qcow2";
    std::error_code ec;
    std::filesystem::remove(temporary, ec);
    if (!ConvertImage(runtimeDir, target, temporary, false) || !CheckImage(runtimeDir, temporary)) {
        std::filesystem::remove(temporary, ec);
        result.detail = L"تعذر ضغط قرص البيانات بشكل آمن.";
        return result;
    }

    std::wstring replaceError;
    if (!AtomicReplace(temporary, target, &replaceError)) {
        std::filesystem::remove(temporary, ec);
        result.detail = replaceError;
        return result;
    }
    MarkStandaloneData(dataDirectory);

    result.ok = true;
    result.artifact = target;
    result.detail = L"تم فحص بيانات الجوال وإعادة ضغط ملف التخزين بنجاح.";
    return result;
}

} // namespace jawal
