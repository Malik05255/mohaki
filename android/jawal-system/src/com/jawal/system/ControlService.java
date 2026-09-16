package com.jawal.system;

import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.IBinder;
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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public final class ControlService extends Service {
    private static final String TAG = "JawalControl";
    private static final int HOST_CONTROL_PORT = 27185;
    private static final int ARM64_RESULT_PORT = 27187;
    private static final int ARM64_MAGIC = 0x4A415236; // JAR6

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

                    String command = reader.readLine();
                    writer.write(handleCommand(command == null ? "" : command.trim()));
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
        if ("ARM64_RESULT".equals(command)) {
            return "OK " + arm64Result.get();
        }
        if (command.startsWith("PACKAGE ")) {
            String packageName = command.substring("PACKAGE ".length()).trim();
            return isInstalled(packageName) ? "OK INSTALLED" : "OK MISSING";
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

    private boolean isInstalled(String packageName) {
        try {
            getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException ignored) {
            return false;
        }
    }

    private void serveArm64Results() {
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
