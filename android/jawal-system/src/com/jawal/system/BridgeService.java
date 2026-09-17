package com.jawal.system;

import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;
import android.os.StatFs;
import android.os.SystemProperties;
import android.provider.MediaStore;
import android.util.Log;
import android.webkit.WebView;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedWriter;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLConnection;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

public final class BridgeService extends Service {
    private static final String TAG = "JawalSystem";
    private static final int PACKAGE_PORT = 27183;
    private static final int HEALTH_PORT = 27184;
    private static final int FILE_PORT = 27188;
    private static final int PACKAGE_MAGIC = 0x4A41504B; // JAPK
    private static final int PACKAGE_PROTOCOL_VERSION = 2;
    private static final int FILE_MAGIC = 0x4A46494C; // JFIL
    private static final int FILE_PROTOCOL_VERSION = 1;
    private static final long MAX_TRANSFER_BYTES = 16L * 1024L * 1024L * 1024L;

    private final ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService healthExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService installExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService fileAcceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService fileTransferExecutor = Executors.newSingleThreadExecutor();
    private volatile ServerSocket packageServer;
    private volatile ServerSocket healthServer;
    private volatile ServerSocket fileServer;

    private static final class InstallOutcome {
        final int status;
        final String packageName;

        InstallOutcome(int status, String packageName) {
            this.status = status;
            this.packageName = packageName == null ? "" : packageName;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        acceptExecutor.execute(this::servePackages);
        healthExecutor.execute(this::serveHealth);
        fileAcceptExecutor.execute(this::serveFiles);
    }

    private void servePackages() {
        try (ServerSocket socket = new ServerSocket(PACKAGE_PORT, 1, InetAddress.getByName("0.0.0.0"))) {
            packageServer = socket;
            Log.i(TAG, "Jawal package bridge ready on private VM port " + PACKAGE_PORT);
            while (!Thread.currentThread().isInterrupted()) {
                final Socket client = socket.accept();
                installExecutor.execute(() -> handlePackageClient(client));
            }
        } catch (IOException error) {
            if (packageServer != null && !packageServer.isClosed()) {
                Log.e(TAG, "Package bridge stopped unexpectedly", error);
            }
        }
    }

    private void serveFiles() {
        try (ServerSocket socket = new ServerSocket(FILE_PORT, 1, InetAddress.getByName("0.0.0.0"))) {
            fileServer = socket;
            Log.i(TAG, "Jawal file bridge ready on private VM port " + FILE_PORT);
            while (!Thread.currentThread().isInterrupted()) {
                final Socket client = socket.accept();
                fileTransferExecutor.execute(() -> handleFileClient(client));
            }
        } catch (IOException error) {
            if (fileServer != null && !fileServer.isClosed()) {
                Log.e(TAG, "File bridge stopped unexpectedly", error);
            }
        }
    }

    private void serveHealth() {
        try (ServerSocket socket = new ServerSocket(HEALTH_PORT, 2, InetAddress.getByName("0.0.0.0"))) {
            healthServer = socket;
            Log.i(TAG, "Jawal health bridge ready on private VM port " + HEALTH_PORT);
            while (!Thread.currentThread().isInterrupted()) {
                try (Socket client = socket.accept()) {
                    final String source = client.getInetAddress().getHostAddress();
                    if (!"10.0.2.2".equals(source)) {
                        Log.w(TAG, "Rejected health probe from " + source);
                        continue;
                    }
                    final BufferedWriter writer = new BufferedWriter(
                            new OutputStreamWriter(client.getOutputStream(), StandardCharsets.UTF_8));
                    writer.write(buildHealthJson());
                    writer.newLine();
                    writer.flush();
                } catch (Exception error) {
                    Log.w(TAG, "Health probe failed", error);
                }
            }
        } catch (IOException error) {
            if (healthServer != null && !healthServer.isClosed()) {
                Log.e(TAG, "Health bridge stopped unexpectedly", error);
            }
        }
    }

    private String buildHealthJson() {
        final PackageManager pm = getPackageManager();
        String webViewPackage = "";
        try {
            final PackageInfo webView = WebView.getCurrentWebViewPackage();
            if (webView != null) webViewPackage = webView.packageName;
        } catch (Throwable error) {
            Log.w(TAG, "Unable to query WebView provider", error);
        }

        boolean networkInternet = false;
        boolean networkValidated = false;
        try {
            final ConnectivityManager connectivity = getSystemService(ConnectivityManager.class);
            final Network active = connectivity != null ? connectivity.getActiveNetwork() : null;
            final NetworkCapabilities capabilities =
                    connectivity != null && active != null ? connectivity.getNetworkCapabilities(active) : null;
            networkInternet = capabilities != null &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
            networkValidated = capabilities != null &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        } catch (Throwable error) {
            Log.w(TAG, "Unable to query network health", error);
        }

        long freeDataBytes = 0L;
        try {
            freeDataBytes = new StatFs(getDataDir().getAbsolutePath()).getAvailableBytes();
        } catch (Throwable error) {
            Log.w(TAG, "Unable to query data storage", error);
        }

        final boolean touchscreen = pm.hasSystemFeature("android.hardware.touchscreen");
        final boolean portrait = pm.hasSystemFeature("android.hardware.screen.portrait");
        final boolean audioOutput = pm.hasSystemFeature("android.hardware.audio.output");
        final boolean microphone = pm.hasSystemFeature("android.hardware.microphone");
        final boolean smokeInstalled = isPackageInstalled(pm, "com.jawal.smoke");
        final int densityDpi = getResources().getDisplayMetrics().densityDpi;
        final int smallestScreenWidthDp = getResources().getConfiguration().smallestScreenWidthDp;
        final String buildCharacteristics = SystemProperties.get("ro.build.characteristics", "");

        final StringBuilder abis = new StringBuilder();
        for (int index = 0; index < Build.SUPPORTED_ABIS.length; ++index) {
            if (index > 0) abis.append(',');
            abis.append(Build.SUPPORTED_ABIS[index]);
        }

        final String nativeBridge = SystemProperties.get("ro.dalvik.vm.native.bridge", "0");

        return "{" +
                "\"ready\":true," +
                "\"sdk\":" + Build.VERSION.SDK_INT + "," +
                "\"release\":\"" + escapeJson(Build.VERSION.RELEASE) + "\"," +
                "\"abis\":\"" + escapeJson(abis.toString()) + "\"," +
                "\"nativeBridge\":\"" + escapeJson(nativeBridge) + "\"," +
                "\"buildCharacteristics\":\"" + escapeJson(buildCharacteristics) + "\"," +
                "\"densityDpi\":" + densityDpi + "," +
                "\"smallestScreenWidthDp\":" + smallestScreenWidthDp + "," +
                "\"webview\":\"" + escapeJson(webViewPackage) + "\"," +
                "\"networkInternet\":" + networkInternet + "," +
                "\"networkValidated\":" + networkValidated + "," +
                "\"audioOutput\":" + audioOutput + "," +
                "\"microphone\":" + microphone + "," +
                "\"touchscreen\":" + touchscreen + "," +
                "\"portrait\":" + portrait + "," +
                "\"smokeInstalled\":" + smokeInstalled + "," +
                "\"dataFreeBytes\":" + freeDataBytes +
                "}";
    }

    private static boolean isPackageInstalled(PackageManager pm, String packageName) {
        try {
            pm.getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException ignored) {
            return false;
        }
    }

    private static String escapeJson(String value) {
        if (value == null) return "";
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private void writeInstallReply(DataOutputStream output, int status, String packageName) throws IOException {
        byte[] packageBytes = packageName == null ? new byte[0] : packageName.getBytes(StandardCharsets.UTF_8);
        if (packageBytes.length > 4096) packageBytes = new byte[0];
        output.writeInt(status);
        output.writeInt(packageBytes.length);
        if (packageBytes.length > 0) output.write(packageBytes);
        output.flush();
    }

    private void handlePackageClient(Socket client) {
        try (client;
             DataInputStream input = new DataInputStream(new BufferedInputStream(client.getInputStream()));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(client.getOutputStream()))) {

            final String source = client.getInetAddress().getHostAddress();
            if (!"10.0.2.2".equals(source)) {
                Log.w(TAG, "Rejected bridge connection from " + source);
                writeInstallReply(output, -10, "");
                return;
            }

            if (input.readInt() != PACKAGE_MAGIC || input.readInt() != PACKAGE_PROTOCOL_VERSION) {
                writeInstallReply(output, -11, "");
                return;
            }

            final long length = input.readLong();
            if (length <= 0 || length > MAX_TRANSFER_BYTES) {
                writeInstallReply(output, -12, "");
                return;
            }

            final InstallOutcome outcome = installFromStream(input, length);
            writeInstallReply(output, outcome.status, outcome.packageName);
        } catch (Exception error) {
            Log.e(TAG, "APK bridge request failed", error);
        }
    }

    private InstallOutcome installFromStream(DataInputStream input, long length) {
        final PackageInstaller installer = getPackageManager().getPackageInstaller();
        final PackageInstaller.SessionParams params =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setInstallReason(PackageInstaller.INSTALL_REASON_USER);
        params.setSize(length);

        int sessionId = -1;
        BroadcastReceiver receiver = null;
        try {
            sessionId = installer.createSession(params);
            try (PackageInstaller.Session session = installer.openSession(sessionId);
                 OutputStream apk = session.openWrite("base.apk", 0, length)) {

                final byte[] buffer = new byte[256 * 1024];
                long remaining = length;
                while (remaining > 0) {
                    final int count = input.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                    if (count < 0) throw new IOException("APK stream ended early");
                    apk.write(buffer, 0, count);
                    remaining -= count;
                }
                session.fsync(apk);

                final String action = getPackageName() + ".INSTALL_RESULT." + sessionId;
                final CountDownLatch finished = new CountDownLatch(1);
                final AtomicInteger result = new AtomicInteger(PackageInstaller.STATUS_FAILURE);
                final AtomicReference<String> packageName = new AtomicReference<>("");

                receiver = new BroadcastReceiver() {
                    @Override
                    public void onReceive(Context context, Intent intent) {
                        final int status = intent.getIntExtra(
                                PackageInstaller.EXTRA_STATUS,
                                PackageInstaller.STATUS_FAILURE);

                        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                            final Intent confirmation = intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class);
                            if (confirmation != null) {
                                confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                startActivity(confirmation);
                                return;
                            }
                        }

                        result.set(status);
                        String installed = intent.getStringExtra(PackageInstaller.EXTRA_PACKAGE_NAME);
                        if (installed != null) packageName.set(installed);
                        finished.countDown();
                    }
                };
                registerReceiver(receiver, new IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);

                final Intent callback = new Intent(action).setPackage(getPackageName());
                final PendingIntent pending = PendingIntent.getBroadcast(
                        this,
                        sessionId,
                        callback,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
                session.commit(pending.getIntentSender());

                if (!finished.await(120, TimeUnit.SECONDS)) {
                    Log.w(TAG, "Timed out waiting for package installer session " + sessionId);
                    return new InstallOutcome(PackageInstaller.STATUS_FAILURE_TIMEOUT, "");
                }
                return new InstallOutcome(result.get(), packageName.get());
            }
        } catch (Exception error) {
            Log.e(TAG, "Package installation failed", error);
            if (sessionId >= 0) {
                try { installer.abandonSession(sessionId); } catch (Exception ignored) { }
            }
            return new InstallOutcome(PackageInstaller.STATUS_FAILURE, "");
        } finally {
            if (receiver != null) {
                try { unregisterReceiver(receiver); } catch (Exception ignored) { }
            }
        }
    }

    private void handleFileClient(Socket client) {
        Uri inserted = null;
        try (client;
             DataInputStream input = new DataInputStream(new BufferedInputStream(client.getInputStream()));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(client.getOutputStream()))) {
            if (!"10.0.2.2".equals(client.getInetAddress().getHostAddress())) {
                output.writeInt(-20); output.flush(); return;
            }
            if (input.readInt() != FILE_MAGIC || input.readInt() != FILE_PROTOCOL_VERSION) {
                output.writeInt(-21); output.flush(); return;
            }
            final int nameLength = input.readInt();
            final long length = input.readLong();
            if (nameLength <= 0 || nameLength > 1024 || length <= 0 || length > MAX_TRANSFER_BYTES) {
                output.writeInt(-22); output.flush(); return;
            }
            byte[] nameBytes = new byte[nameLength];
            input.readFully(nameBytes);
            String safeName = new String(nameBytes, StandardCharsets.UTF_8)
                    .replace('/', '_').replace('\\', '_').replace('\u0000', '_');
            if (safeName.isEmpty() || ".".equals(safeName) || "..".equals(safeName)) {
                output.writeInt(-23); output.flush(); return;
            }

            ContentResolver resolver = getContentResolver();
            ContentValues values = new ContentValues();
            values.put(MediaStore.Downloads.DISPLAY_NAME, safeName);
            String mime = URLConnection.guessContentTypeFromName(safeName);
            values.put(MediaStore.Downloads.MIME_TYPE, mime == null ? "application/octet-stream" : mime);
            values.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Jawal");
            values.put(MediaStore.Downloads.IS_PENDING, 1);
            inserted = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (inserted == null) {
                output.writeInt(-24); output.flush(); return;
            }

            try (OutputStream target = resolver.openOutputStream(inserted, "w")) {
                if (target == null) throw new IOException("MediaStore output unavailable");
                byte[] buffer = new byte[256 * 1024];
                long remaining = length;
                while (remaining > 0) {
                    int count = input.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                    if (count < 0) throw new IOException("File stream ended early");
                    target.write(buffer, 0, count);
                    remaining -= count;
                }
                target.flush();
            }

            ContentValues ready = new ContentValues();
            ready.put(MediaStore.Downloads.IS_PENDING, 0);
            resolver.update(inserted, ready, null, null);
            output.writeInt(0);
            output.flush();
            inserted = null;
        } catch (Exception error) {
            Log.e(TAG, "File bridge request failed", error);
            if (inserted != null) {
                try { getContentResolver().delete(inserted, null, null); } catch (Exception ignored) { }
            }
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
        try { if (packageServer != null) packageServer.close(); } catch (IOException ignored) { }
        try { if (healthServer != null) healthServer.close(); } catch (IOException ignored) { }
        try { if (fileServer != null) fileServer.close(); } catch (IOException ignored) { }
        acceptExecutor.shutdownNow();
        healthExecutor.shutdownNow();
        installExecutor.shutdownNow();
        fileAcceptExecutor.shutdownNow();
        fileTransferExecutor.shutdownNow();
        super.onDestroy();
    }
}
