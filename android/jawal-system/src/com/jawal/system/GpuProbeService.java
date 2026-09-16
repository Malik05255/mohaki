package com.jawal.system;

import android.app.Service;
import android.content.Intent;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.IBinder;
import android.util.Log;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class GpuProbeService extends Service {
    private static final String TAG = "JawalGpuProbe";
    private static final int PORT = 27186;

    private final ExecutorService executor = Executors.newFixedThreadPool(2);
    private volatile ServerSocket server;
    private volatile String resultJson = "{\"ready\":false}";

    @Override
    public void onCreate() {
        super.onCreate();
        executor.execute(() -> resultJson = runProbe());
        executor.execute(this::serve);
    }

    private String runProbe() {
        EGLDisplay display = EGL14.EGL_NO_DISPLAY;
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            if (display == EGL14.EGL_NO_DISPLAY) throw new IllegalStateException("eglGetDisplay failed");

            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                throw new IllegalStateException("eglInitialize failed");
            }

            int[] configAttrs = {
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_NONE
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            if (!EGL14.eglChooseConfig(display, configAttrs, 0, configs, 0, 1, count, 0) || count[0] < 1) {
                throw new IllegalStateException("eglChooseConfig failed");
            }

            int[] contextAttrs = {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE};
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, contextAttrs, 0);
            if (context == EGL14.EGL_NO_CONTEXT) throw new IllegalStateException("eglCreateContext failed");

            int[] surfaceAttrs = {EGL14.EGL_WIDTH, 256, EGL14.EGL_HEIGHT, 256, EGL14.EGL_NONE};
            surface = EGL14.eglCreatePbufferSurface(display, configs[0], surfaceAttrs, 0);
            if (surface == EGL14.EGL_NO_SURFACE) throw new IllegalStateException("eglCreatePbufferSurface failed");
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                throw new IllegalStateException("eglMakeCurrent failed");
            }

            final String renderer = safe(GLES20.glGetString(GLES20.GL_RENDERER));
            final String vendor = safe(GLES20.glGetString(GLES20.GL_VENDOR));
            final String glVersion = safe(GLES20.glGetString(GLES20.GL_VERSION));

            for (int i = 0; i < 30; ++i) {
                GLES20.glClearColor((i & 1) == 0 ? 0.1f : 0.2f, 0.2f, 0.3f, 1.0f);
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                EGL14.eglSwapBuffers(display, surface);
            }
            GLES20.glFinish();

            final int frames = 600;
            final long started = System.nanoTime();
            for (int i = 0; i < frames; ++i) {
                float phase = (i % 100) / 100.0f;
                GLES20.glClearColor(phase, 0.25f, 1.0f - phase, 1.0f);
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                if (!EGL14.eglSwapBuffers(display, surface)) {
                    throw new IllegalStateException("eglSwapBuffers failed at frame " + i);
                }
            }
            GLES20.glFinish();
            final long elapsedNs = Math.max(1L, System.nanoTime() - started);
            final double swapsPerSecond = frames * 1_000_000_000.0 / elapsedNs;

            final String lower = renderer.toLowerCase(Locale.ROOT);
            final boolean software = lower.contains("llvmpipe") ||
                    lower.contains("softpipe") ||
                    lower.contains("swiftshader") ||
                    lower.contains("software rasterizer");

            return "{" +
                    "\"ready\":true," +
                    "\"passed\":" + (!software && swapsPerSecond >= 30.0) + "," +
                    "\"softwareRenderer\":" + software + "," +
                    "\"renderer\":\"" + escape(renderer) + "\"," +
                    "\"vendor\":\"" + escape(vendor) + "\"," +
                    "\"glVersion\":\"" + escape(glVersion) + "\"," +
                    "\"frames\":" + frames + "," +
                    "\"swapsPerSecond\":" + String.format(Locale.US, "%.2f", swapsPerSecond) +
                    "}";
        } catch (Throwable error) {
            Log.e(TAG, "GPU probe failed", error);
            return "{\"ready\":true,\"passed\":false,\"error\":\"" + escape(error.toString()) + "\"}";
        } finally {
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface);
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
                EGL14.eglTerminate(display);
            }
        }
    }

    private void serve() {
        try (ServerSocket socket = new ServerSocket(PORT, 2, InetAddress.getByName("0.0.0.0"))) {
            server = socket;
            while (!Thread.currentThread().isInterrupted()) {
                try (Socket client = socket.accept()) {
                    String source = client.getInetAddress().getHostAddress();
                    if (!"10.0.2.2".equals(source)) {
                        Log.w(TAG, "Rejected GPU probe client from " + source);
                        continue;
                    }
                    BufferedWriter writer = new BufferedWriter(
                            new OutputStreamWriter(client.getOutputStream(), StandardCharsets.UTF_8));
                    writer.write(resultJson);
                    writer.newLine();
                    writer.flush();
                } catch (Exception error) {
                    Log.w(TAG, "GPU probe response failed", error);
                }
            }
        } catch (IOException error) {
            if (server != null && !server.isClosed()) Log.e(TAG, "GPU probe server failed", error);
        }
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static String escape(String value) {
        return safe(value).replace("\\", "\\\\").replace("\"", "\\\"");
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
        try { if (server != null) server.close(); } catch (IOException ignored) { }
        executor.shutdownNow();
        super.onDestroy();
    }
}
