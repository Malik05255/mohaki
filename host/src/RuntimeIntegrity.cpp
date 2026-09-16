#include "RuntimeIntegrity.hpp"

#include <bcrypt.h>
#include <windows.h>

#include <array>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace jawal {
namespace {

std::wstring ToWideAscii(const std::string& value) {
    return std::wstring(value.begin(), value.end());
}

bool Sha256File(const std::filesystem::path& path, std::string* hex) {
    if (!hex) return false;

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectLength = 0;
    DWORD hashLength = 0;
    DWORD copied = 0;
    std::vector<unsigned char> object;
    std::vector<unsigned char> digest;
    bool ok = false;

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) goto done;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&objectLength), sizeof(objectLength), &copied, 0) < 0) goto done;
    if (BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                          reinterpret_cast<PUCHAR>(&hashLength), sizeof(hashLength), &copied, 0) < 0) goto done;

    object.resize(objectLength);
    digest.resize(hashLength);
    if (BCryptCreateHash(algorithm, &hash, object.data(), objectLength, nullptr, 0, 0) < 0) goto done;

    {
        std::ifstream input(path, std::ios::binary);
        if (!input) goto done;
        std::array<unsigned char, 1024 * 1024> buffer{};
        while (input) {
            input.read(reinterpret_cast<char*>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
            const auto count = input.gcount();
            if (count > 0 && BCryptHashData(hash, buffer.data(), static_cast<ULONG>(count), 0) < 0) goto done;
        }
    }

    if (BCryptFinishHash(hash, digest.data(), hashLength, 0) < 0) goto done;

    {
        std::ostringstream out;
        out << std::hex << std::setfill('0');
        for (const auto byte : digest) out << std::setw(2) << static_cast<unsigned>(byte);
        *hex = out.str();
    }
    ok = true;

done:
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

std::string Lower(std::string value) {
    for (char& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return value;
}

} // namespace

bool VerifyRuntimeIntegrity(const std::filesystem::path& runtimeDir, std::wstring* error) {
    const auto manifestPath = runtimeDir / L"runtime.sha256";
    std::ifstream manifest(manifestPath);
    if (!manifest) {
        if (error) *error = L"ملف التحقق runtime.sha256 غير موجود.";
        return false;
    }

    std::size_t verified = 0;
    std::string line;
    while (std::getline(manifest, line)) {
        if (line.empty()) continue;
        if (line.size() < 66) {
            if (error) *error = L"ملف التحقق من Runtime غير صالح.";
            return false;
        }

        const std::string expected = Lower(line.substr(0, 64));
        std::size_t offset = 64;
        while (offset < line.size() && std::isspace(static_cast<unsigned char>(line[offset]))) ++offset;
        if (offset < line.size() && line[offset] == '*') ++offset;
        while (offset < line.size() && std::isspace(static_cast<unsigned char>(line[offset]))) ++offset;
        if (offset >= line.size()) {
            if (error) *error = L"مسار ملف مفقود داخل runtime.sha256.";
            return false;
        }

        std::string relativeText = line.substr(offset);
        for (char& c : relativeText) if (c == '/') c = '\\';
        const auto relative = std::filesystem::path(ToWideAscii(relativeText));
        const auto file = runtimeDir / relative;
        if (!std::filesystem::exists(file)) {
            if (error) *error = L"ملف Runtime مفقود: " + relative.wstring();
            return false;
        }

        std::string actual;
        if (!Sha256File(file, &actual)) {
            if (error) *error = L"تعذر حساب SHA-256 للملف: " + relative.wstring();
            return false;
        }
        if (Lower(actual) != expected) {
            if (error) *error = L"فشل فحص سلامة Runtime: " + relative.wstring();
            return false;
        }
        ++verified;
    }

    if (verified < 6) {
        if (error) *error = L"Runtime integrity manifest لا يغطي ملفات كافية.";
        return false;
    }
    return true;
}

} // namespace jawal
