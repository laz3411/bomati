package com.bumati.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BumatiAlertReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        BumatiNotifications.dismiss(context, intent.getStringExtra("token"));
    }
}
