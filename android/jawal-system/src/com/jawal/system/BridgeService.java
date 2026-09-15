package com.jawal.system;

import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInstaller;
import android.os.IBinder;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class BridgeService extends Service {
    private static final String TAG = "JawalSystem";
    private static final int PORT = 27183;
    private static final int MAGIC = 0x4A41504B; // JAPK
    private static final int PROTOCOL_VERSION = 1;
    private static final long MAX_APK_BYTES = 16L * 1024L * 1024L * 1024L;

    private final ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService installExecutor = Executors.newSingleThreadExecutor();
    private volatile ServerSocket server;

    @Override
    public void onCreate() {
        super.onCreate();
        acceptExecutor.execute(this::serve);
    }

    private void serve() {
        try (ServerSocket socket = new ServerSocket(PORT, 1, InetAddress.getByName("0.0.0.0"))) {
            server = socket;
            Log.i(TAG, "Jawal package bridge ready on private VM port " + PORT);
            while (!Thread.currentThread().isInterrupted()) {
                final Socket client = socket.accept();
                installExecutor.execute(() -> handleClient(client));
            }
        } catch (IOException error) {
            if (server != null && !server.isClosed()) {
                Log.e(TAG, "Package bridge stopped unexpectedly", error);
            }
        }
    }

    private void handleClient(Socket client) {
        try (client;
             DataInputStream input = new DataInputStream(new BufferedInputStream(client.getInputStream()));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(client.getOutputStream()))) {

            // QEMU user-mode host forwarding normally arrives from the virtual
            // gateway. Do not expose a privileged installer to arbitrary guest apps.
            final String source = client.getInetAddress().getHostAddress();
            if (!("10.0.2.2".equals(source) || "127.0.0.1".equals(source))) {
                Log.w(TAG, "Rejected bridge connection from " + source);
                output.writeInt(-10);
                output.flush();
                return;
            }

            if (input.readInt() != MAGIC || input.readInt() != PROTOCOL_VERSION) {
                output.writeInt(-11);
                output.flush();
                return;
            }

            final long length = input.readLong();
            if (length <= 0 || length > MAX_APK_BYTES) {
                output.writeInt(-12);
                output.flush();
                return;
            }

            final int status = installFromStream(input, length);
            output.writeInt(status);
            output.flush();
        } catch (Exception error) {
            Log.e(TAG, "APK bridge request failed", error);
        }
    }

    private int installFromStream(DataInputStream input, long length) {
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

                receiver = new BroadcastReceiver() {
                    @Override
                    public void onReceive(Context context, Intent intent) {
                        result.set(intent.getIntExtra(
                                PackageInstaller.EXTRA_STATUS,
                                PackageInstaller.STATUS_FAILURE));
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
                    return PackageInstaller.STATUS_FAILURE_TIMEOUT;
                }
                return result.get();
            }
        } catch (Exception error) {
            Log.e(TAG, "Package installation failed", error);
            if (sessionId >= 0) {
                try { installer.abandonSession(sessionId); } catch (Exception ignored) { }
            }
            return PackageInstaller.STATUS_FAILURE;
        } finally {
            if (receiver != null) {
                try { unregisterReceiver(receiver); } catch (Exception ignored) { }
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
        try {
            if (server != null) server.close();
        } catch (IOException ignored) { }
        acceptExecutor.shutdownNow();
        installExecutor.shutdownNow();
        super.onDestroy();
    }
}
