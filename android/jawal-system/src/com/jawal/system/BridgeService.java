package com.jawal.system;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;

public final class BridgeService extends Service {
    private static final String TAG = "JawalSystem";

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "Jawal guest bridge ready");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }
}
