package com.jawal.system;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public final class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "JawalSystem";

    @Override
    public void onReceive(Context context, Intent intent) {
        Log.i(TAG, "Jawal guest integration boot event: " + intent.getAction());
        context.startService(new Intent(context, BridgeService.class));
    }
}
