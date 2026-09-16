package com.bumati.app;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Build;
import android.webkit.JavascriptInterface;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

public final class BumatiJavascriptBridge {
    private static final int NOTIFICATION_PERMISSION_REQUEST = 4101;
    private static final String PREFS = "bumati_native";
    private static final String PREF_PERMISSION_REQUESTED = "notification_permission_requested";
    private final MainActivity activity;

    BumatiJavascriptBridge(MainActivity activity) {
        this.activity = activity;
    }

    @JavascriptInterface
    public void requestNotificationPermission() {
        activity.runOnUiThread(() -> {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return;
            if (ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
                    == PackageManager.PERMISSION_GRANTED) return;

            boolean alreadyRequested = activity.getSharedPreferences(PREFS, 0)
                    .getBoolean(PREF_PERMISSION_REQUESTED, false);
            if (alreadyRequested) return;

            activity.getSharedPreferences(PREFS, 0).edit()
                    .putBoolean(PREF_PERMISSION_REQUESTED, true)
                    .apply();
            ActivityCompat.requestPermissions(
                    activity,
                    new String[]{Manifest.permission.POST_NOTIFICATIONS},
                    NOTIFICATION_PERMISSION_REQUEST
            );
        });
    }

    @JavascriptInterface
    public String getNotificationPermissionState() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "granted";
        return ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED ? "granted" : "denied";
    }

    @JavascriptInterface
    public void showStopNotification(
            String title,
            String body,
            String sound,
            int durationSeconds,
            boolean playSound
    ) {
        BumatiNotifications.postStopAlert(
                activity,
                title,
                body,
                sound,
                durationSeconds,
                playSound
        );
    }

    @JavascriptInterface
    public void startReservationWatch(String reservationKey, String stopName, String sound, int durationSeconds) {
        requestNotificationPermission();
        BumatiReservationService.start(
                activity,
                reservationKey,
                stopName,
                sound,
                durationSeconds
        );
    }

    @JavascriptInterface
    public void stopReservationWatch() {
        BumatiReservationService.stop(activity);
    }

    @JavascriptInterface
    public void dismissReservationAlert(String token) {
        activity.runOnUiThread(() -> BumatiNotifications.dismiss(activity, token));
    }

    @JavascriptInterface
    public boolean isAlertDismissed(String token) {
        return activity.getSharedPreferences("bumati_alerts", 0).getBoolean("dismissed:" + token, false);
    }
}
