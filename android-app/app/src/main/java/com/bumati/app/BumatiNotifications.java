package com.bumati.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.os.Build;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

final class BumatiNotifications {
    static final String WATCH_CHANNEL = "bumati_reservation_watch_v1";
    private static final String ALERT_CHANNEL_CLASSIC = "bumati_stop_classic_v1";
    private static final String ALERT_CHANNEL_GENTLE = "bumati_stop_gentle_v1";
    private static final String ALERT_CHANNEL_URGENT = "bumati_stop_urgent_v1";
    static final int WATCH_NOTIFICATION_ID = 1101;
    private static final int STOP_NOTIFICATION_ID = 1201;

    private BumatiNotifications() {}

    static void createChannels(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) return;

        NotificationChannel watch = new NotificationChannel(
                WATCH_CHANNEL,
                context.getString(R.string.reservation_watch_channel),
                NotificationManager.IMPORTANCE_LOW
        );
        watch.setDescription("예약 정류장 도착 신호를 백그라운드에서 확인합니다.");
        watch.setShowBadge(false);
        watch.setSound(null, null);
        manager.createNotificationChannel(watch);

        createAlertChannel(manager, ALERT_CHANNEL_CLASSIC, "기본 하차 알림", new long[]{0, 320, 110, 320, 260});
        createAlertChannel(manager, ALERT_CHANNEL_GENTLE, "부드러운 하차 알림", new long[]{0, 420, 260, 420});
        createAlertChannel(manager, ALERT_CHANNEL_URGENT, "긴급 하차 알림", new long[]{0, 260, 90, 260, 90, 420});
    }

    private static void createAlertChannel(
            NotificationManager manager,
            String id,
            String name,
            long[] vibration
    ) {
        NotificationChannel channel = new NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("예약 정류장 도착 시 소리와 진동으로 알려줍니다.");
        channel.enableVibration(true);
        channel.setVibrationPattern(vibration);
        channel.enableLights(true);
        channel.setLightColor(Color.rgb(2, 132, 199));
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build();
        channel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION), attributes);
        manager.createNotificationChannel(channel);
    }

    static NotificationCompat.Builder buildWatchNotification(Context context, String stopName) {
        Intent openIntent = new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPendingIntent = PendingIntent.getActivity(
                context,
                2001,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Intent stopIntent = new Intent(context, BumatiReservationService.class)
                .setAction(BumatiReservationService.ACTION_STOP);
        PendingIntent stopPendingIntent = PendingIntent.getService(
                context,
                2002,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        return new NotificationCompat.Builder(context, WATCH_CHANNEL)
                .setSmallIcon(R.drawable.ic_bumati_notification)
                .setContentTitle("BUMATI 하차 예약 감시 중")
                .setContentText(stopName + " 도착 신호를 기다리고 있습니다.")
                .setContentIntent(openPendingIntent)
                .addAction(0, "감시 중지", stopPendingIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW);
    }

    static void postStopAlert(
            Context context,
            String title,
            String body,
            String sound,
            int durationSeconds,
            boolean playSound
    ) {
        createChannels(context);
        String channel = alertChannel(sound);
        long[] vibration = vibration(sound);
        int seconds = Math.max(5, Math.min(durationSeconds, 60));

        Intent openIntent = new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPendingIntent = PendingIntent.getActivity(
                context,
                2003,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_bumati_notification)
                .setContentTitle(title == null || title.trim().isEmpty() ? "BUMATI 하차 알림" : title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openPendingIntent)
                .setAutoCancel(true)
                .setTimeoutAfter(seconds * 1000L)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVibrate(vibration)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC);
        if (!playSound) builder.setSilent(true);

        try {
            NotificationManagerCompat.from(context).notify(STOP_NOTIFICATION_ID, builder.build());
        } catch (SecurityException ignored) {
            // Android 13+ 알림 권한을 거부한 경우 앱 화면 알림은 계속 동작합니다.
        }
    }

    private static String alertChannel(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return ALERT_CHANNEL_GENTLE;
        if ("urgent".equalsIgnoreCase(sound)) return ALERT_CHANNEL_URGENT;
        return ALERT_CHANNEL_CLASSIC;
    }

    private static long[] vibration(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return new long[]{0, 420, 260, 420};
        if ("urgent".equalsIgnoreCase(sound)) return new long[]{0, 260, 90, 260, 90, 420};
        return new long[]{0, 320, 110, 320, 260};
    }
}
