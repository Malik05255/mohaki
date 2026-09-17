package com.jawal.system;

import android.app.ActivityManager;
import android.app.Service;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.IBinder;
import android.os.SystemProperties;
import android.util.Base64;
import android.util.Log;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public final class ControlService extends Service {
    private static final String TAG = "JawalControl";
    private static final int HOST_CONTROL_PORT = 27185;
    private static final int ARM64_RESULT_PORT = 27187;
    private static final int ARM64_MAGIC = 0x4A415236; // JAR6
    private static final int MAX_CLIPBOARD_BYTES = 64 * 1024;
    private static final int SESSION_TOKEN_CHARS = 64;

    private final ExecutorService executor = Executors.newFixedThreadPool(2);
    private final AtomicInteger arm64Result = new AtomicInteger(0);
    private volatile ServerSocket controlServer;
    private volatile ServerSocket arm64Server;

    @Override
    public void onCreate() {
        super.onCreate();
        executor.execute(this::serveHostControl);
        executor.execute(this::serveArm64Results);
    }

    private static boolean validSessionToken(String value) {
        if (value == null || value.length() != SESSION_TOKEN_CHARS) return false;
        for (int i = 0; i < value.length(); ++i) {
            if (Character.digit(value.charAt(i), 16) < 0) return false;
        }
        return true;
    }

    private boolean sessionAuthorized(String candidate) {
        final String expected = SystemProperties.get("ro.boot.jawal_session", "");
        if (!validSessionToken(expected) || !validSessionToken(candidate)) return false;
        return MessageDigest.isEqual(
                expected.getBytes(StandardCharsets.US_ASCII),
                candidate.getBytes(StandardCharsets.US_ASCII));
    }

    private String authorizeCommand(String request) {
        if (request == null || !request.startsWith("AUTH ")) return null;
        final int tokenStart = "AUTH ".length();
        final int tokenEnd = request.indexOf(' ', tokenStart);
        if (tokenEnd <= tokenStart) return null;
        final String token = request.substring(tokenStart, tokenEnd);
        if (!sessionAuthorized(token)) return null;
        final String command = request.substring(tokenEnd + 1).trim();
        return command.isEmpty() ? null : command;
    }

    private void serveHostControl() {
        try (ServerSocket server = new ServerSocket(HOST_CONTROL_PORT, 4, InetAddress.getByName("0.0.0.0"))) {
            controlServer = server;
            while (!Thread.currentThread().isInterrupted()) {
                try (Socket client = server.accept()) {
                    String source = client.getInetAddress().getHostAddress();
                    if (!"10.0.2.2".equals(source)) {
                        Log.w(TAG, "Rejected control client from " + source);
                        continue;
                    }

                    BufferedReader reader = new BufferedReader(
                            new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8));
                    BufferedWriter writer = new BufferedWriter(
                            new OutputStreamWriter(client.getOutputStream(), StandardCharsets.UTF_8));

                    final String command = authorizeCommand(reader.readLine());
                    if (command == null) {
                        Log.w(TAG, "Rejected unauthenticated control request");
                        writer.write("ERR AUTH");
                    } else {
                        writer.write(handleCommand(command));
                    }
                    writer.newLine();
                    writer.flush();
                } catch (Exception error) {
                    Log.w(TAG, "Control request failed", error);
                }
            }
        } catch (IOException error) {
            if (controlServer != null && !controlServer.isClosed()) Log.e(TAG, "Control server failed", error);
        }
    }

    private String handleCommand(String command) {
        if ("PING".equals(command)) return "OK PONG";
        if ("GPU_RESULT".equals(command)) return "OK " + GpuProbeService.getResultJson();
        if ("RESET_ARM64".equals(command)) {
            arm64Result.set(0);
            return "OK";
        }
        if ("ARM64_RESULT".equals(command)) return "OK " + arm64Result.get();
        if ("CLIPBOARD_GET".equals(command)) return clipboardGet();
        if (command.startsWith("CLIPBOARD_SET ")) return clipboardSet(command.substring("CLIPBOARD_SET ".length()));

        if (command.startsWith("PACKAGE ")) {
            String packageName = command.substring("PACKAGE ".length()).trim();
            return isInstalled(packageName) ? "OK INSTALLED" : "OK MISSING";
        }
        if (command.startsWith("PROCESS ")) {
            String packageName = command.substring("PROCESS ".length()).trim();
            return isProcessRunning(packageName) ? "OK RUNNING" : "OK MISSING";
        }
        if (command.startsWith("LAUNCH ")) {
            String packageName = command.substring("LAUNCH ".length()).trim();
            try {
                Intent launch = getPackageManager().getLaunchIntentForPackage(packageName);
                if (launch == null) return "ERR NO_LAUNCH_INTENT";
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(launch);
                return "OK LAUNCHED";
            } catch (Throwable error) {
                Log.e(TAG, "Unable to launch " + packageName, error);
                return "ERR LAUNCH_FAILED";
            }
        }
        return "ERR UNKNOWN_COMMAND";
    }

    private String clipboardGet() {
        try {
            ClipboardManager manager = getSystemService(ClipboardManager.class);
            if (manager == null || !manager.hasPrimaryClip() || manager.getPrimaryClip() == null ||
                    manager.getPrimaryClip().getItemCount() == 0) return "OK -";
            CharSequence value = manager.getPrimaryClip().getItemAt(0).coerceToText(this);
            if (value == null || value.length() == 0) return "OK -";
            byte[] utf8 = value.toString().getBytes(StandardCharsets.UTF_8);
            if (utf8.length > MAX_CLIPBOARD_BYTES) return "ERR CLIPBOARD_TOO_LARGE";
            return "OK " + Base64.encodeToString(utf8, Base64.NO_WRAP);
        } catch (Throwable error) {
            Log.w(TAG, "Clipboard read failed", error);
            return "ERR CLIPBOARD_READ";
        }
    }

    private String clipboardSet(String encoded) {
        try {
            String text;
            if ("-".equals(encoded)) {
                text = "";
            } else {
                byte[] utf8 = Base64.decode(encoded, Base64.DEFAULT);
                if (utf8.length > MAX_CLIPBOARD_BYTES) return "ERR CLIPBOARD_TOO_LARGE";
                text = new String(utf8, StandardCharsets.UTF_8);
            }
            ClipboardManager manager = getSystemService(ClipboardManager.class);
            if (manager == null) return "ERR CLIPBOARD_UNAVAILABLE";
            manager.setPrimaryClip(ClipData.newPlainText("Jawal", text));
            return "OK";
        } catch (Throwable error) {
            Log.w(TAG, "Clipboard write failed", error);
            return "ERR CLIPBOARD_WRITE";
        }
    }

    private boolean isInstalled(String packageName) {
        try {
            getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException ignored) {
            return false;
        }
    }

    private boolean isProcessRunning(String packageName) {
        try {
            ActivityManager manager = getSystemService(ActivityManager.class);
            List<ActivityManager.RunningAppProcessInfo> processes =
                    manager != null ? manager.getRunningAppProcesses() : null;
            if (processes == null) return false;
            for (ActivityManager.RunningAppProcessInfo process : processes) {
                if (process.pkgList == null) continue;
                for (String candidate : process.pkgList) {
                    if (packageName.equals(candidate) &&
                            process.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE) {
                        return true;
                    }
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "Unable to inspect process " + packageName, error);
        }
        return false;
    }

    private void serveArm64Results() {
        // This port exists only inside the guest loopback namespace and is not
        // forwarded to Windows. It is intentionally separate from host control.
        try (ServerSocket server = new ServerSocket(ARM64_RESULT_PORT, 2, InetAddress.getByName("127.0.0.1"))) {
            arm64Server = server;
            while (!Thread.currentThread().isInterrupted()) {
                try (Socket client = server.accept();
                     DataInputStream input = new DataInputStream(client.getInputStream());
                     DataOutputStream output = new DataOutputStream(client.getOutputStream())) {
                    int magic = input.readInt();
                    int result = input.readInt();
                    if (magic == ARM64_MAGIC) {
                        arm64Result.set(result);
                        output.writeInt(0);
                    } else {
                        output.writeInt(-1);
                    }
                    output.flush();
                } catch (Exception error) {
                    Log.w(TAG, "ARM64 result channel failed", error);
                }
            }
        } catch (IOException error) {
            if (arm64Server != null && !arm64Server.isClosed()) Log.e(TAG, "ARM64 result server failed", error);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        try { if (controlServer != null) controlServer.close(); } catch (IOException ignored) { }
        try { if (arm64Server != null) arm64Server.close(); } catch (IOException ignored) { }
        executor.shutdownNow();
        super.onDestroy();
    }
}
