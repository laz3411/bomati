package com.bumati.app;

import android.app.NotificationChannel;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

final class BumatiNotifications {
    // 채널 이름은 Android가 최초 생성 값을 보존하므로 새 ID로 갱신합니다.
    static final String WATCH_CHANNEL = "bumati_reservation_v2";
    private static final String ALERT_CHANNEL_CLASSIC = "bumati_stop_classic_v4";
    private static final String ALERT_CHANNEL_GENTLE = "bumati_stop_gentle_v4";
    private static final String ALERT_CHANNEL_URGENT = "bumati_stop_urgent_v4";
    static final int WATCH_NOTIFICATION_ID = 1101;
    private static final int STOP_NOTIFICATION_ID = 1201;
    private static final Handler ALERT_HANDLER = new Handler(Looper.getMainLooper());
    private static MediaPlayer alertPlayer;
    private static Vibrator alertVibrator;
    private static Context alertContext;
    private static Runnable startRepeatRunnable;
    private static Runnable stopAlertRunnable;
    private static String activeToken = "";

    static Notification postReservationAlert(Context context, String token, String stop, String sound, int duration) {
        if (context.getSharedPreferences("bumati_alerts", 0).getBoolean("handled:" + token, false)) return null;
        context.getSharedPreferences("bumati_alerts", 0).edit().putBoolean("handled:" + token, true).apply();
        activeToken = token;
        return createStopAlert(context, "BUMATI 하차 알림", stop + "에서 하차하세요.", sound, duration, true, false);
    }

    static void dismiss(Context context, String token) {
        String dismissed = token == null ? activeToken : token;
        if (!dismissed.isEmpty()) context.getSharedPreferences("bumati_alerts", 0).edit()
                .putBoolean("handled:" + dismissed, true).putBoolean("dismissed:" + dismissed, true).apply();
        if (token == null || activeToken.isEmpty() || token.equals(activeToken)) {
            stopAlertPlayback();
            NotificationManagerCompat.from(context).cancel(STOP_NOTIFICATION_ID);
            NotificationManagerCompat.from(context).cancel(WATCH_NOTIFICATION_ID);
            context.stopService(new Intent(context, BumatiReservationService.class));
        }
    }

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
        manager.deleteNotificationChannel("bumati_reservation_watch_v1");

        createAlertChannel(context, manager, ALERT_CHANNEL_CLASSIC, "BUMATI 기본 하차 알림", R.raw.bumati_classic, new long[]{0, 260, 90, 260, 90, 420});
        createAlertChannel(context, manager, ALERT_CHANNEL_GENTLE, "BUMATI 부드러운 하차 알림", R.raw.bumati_gentle, new long[]{0, 420, 220, 420});
        createAlertChannel(context, manager, ALERT_CHANNEL_URGENT, "BUMATI 긴급 하차 알림", R.raw.bumati_urgent, new long[]{0, 220, 75, 220, 75, 220, 180, 420});

        // 알림 채널의 소리는 생성 후 변경할 수 없으므로 이전 기본음 채널을 정리합니다.
        manager.deleteNotificationChannel("bumati_stop_classic_v1");
        manager.deleteNotificationChannel("bumati_stop_gentle_v1");
        manager.deleteNotificationChannel("bumati_stop_urgent_v1");
        manager.deleteNotificationChannel("bumati_stop_classic_v2");
        manager.deleteNotificationChannel("bumati_stop_gentle_v2");
        manager.deleteNotificationChannel("bumati_stop_urgent_v2");
        manager.deleteNotificationChannel("bumati_stop_classic_v3");
        manager.deleteNotificationChannel("bumati_stop_gentle_v3");
        manager.deleteNotificationChannel("bumati_stop_urgent_v3");
    }

    private static void createAlertChannel(
            Context context,
            NotificationManager manager,
            String id,
            String name,
            int soundResource,
            long[] vibration
    ) {
        NotificationChannel channel = new NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("예약 정류장 도착 시 소리와 진동으로 알려줍니다.");
        channel.enableVibration(true);
        channel.setLockscreenVisibility(NotificationCompat.VISIBILITY_PUBLIC);
        channel.setVibrationPattern(vibration);
        channel.enableLights(true);
        channel.setLightColor(Color.rgb(2, 132, 199));
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build();
        Uri soundUri = Uri.parse(ContentResolver.SCHEME_ANDROID_RESOURCE
                + "://" + context.getPackageName() + "/" + soundResource);
        channel.setSound(soundUri, attributes);
        manager.createNotificationChannel(channel);
    }

    static NotificationCompat.Builder buildWatchNotification(Context context, String stopName, String key, String stamp) {
        Intent openIntent = new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPendingIntent = PendingIntent.getActivity(
                context,
                2001,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Intent stopIntent = new Intent(context, BumatiReservationService.class)
                .setAction(BumatiReservationService.ACTION_CANCEL)
                .setData(Uri.parse("bumati://cancel/" + Uri.encode(key + "@" + stamp)))
                .putExtra("key", key).putExtra("stamp", stamp);
        PendingIntent stopPendingIntent = PendingIntent.getService(
                context,
                2002,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        return new NotificationCompat.Builder(context, WATCH_CHANNEL)
                .setSmallIcon(R.drawable.ic_bumati_notification)
                .setContentTitle(stopName + " 하차 예정")
                .setContentText("BUMATI 하차 예약")
                .setContentIntent(openPendingIntent)
                .addAction(0, "하차 예약 취소", stopPendingIntent)
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
        createStopAlert(context, title, body, sound, durationSeconds, playSound, true);
    }

    private static Notification createStopAlert(
            Context context,
            String title,
            String body,
            String sound,
            int durationSeconds,
            boolean playSound,
            boolean postNotification
    ) {
        createChannels(context);
        String channel = alertChannel(sound);
        long[] vibration = vibration(sound);
        int alertDuration = Math.max(5, Math.min(durationSeconds, 60));

        Intent openIntent = new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPendingIntent = PendingIntent.getActivity(
                context,
                2003,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Intent dismissIntent = new Intent(context, BumatiAlertReceiver.class)
                .setData(Uri.parse("bumati://dismiss/" + Uri.encode(activeToken)))
                .putExtra("token", activeToken);
        PendingIntent dismissPending = PendingIntent.getBroadcast(context, 2201, dismissIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        PendingIntent cancelReservationPending = null;
        int tokenSeparator = activeToken.lastIndexOf('@');
        if (tokenSeparator > 0 && tokenSeparator < activeToken.length() - 1) {
            String reservationKey = activeToken.substring(0, tokenSeparator);
            String reservationStamp = activeToken.substring(tokenSeparator + 1);
            Intent cancelIntent = new Intent(context, BumatiReservationService.class)
                    .setAction(BumatiReservationService.ACTION_CANCEL)
                    .setData(Uri.parse("bumati://cancel-alert/" + Uri.encode(activeToken)))
                    .putExtra("key", reservationKey)
                    .putExtra("stamp", reservationStamp);
            cancelReservationPending = PendingIntent.getService(context, 2202, cancelIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        }

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_bumati_notification)
                .setContentTitle(title == null || title.trim().isEmpty() ? "BUMATI 하차 알림" : title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(dismissPending)
                .setDeleteIntent(dismissPending)
                .addAction(0, "알림 해제", dismissPending)
                .setAutoCancel(true)
                .setTimeoutAfter(alertDuration * 1000L)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVibrate(vibration)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC);
        if (cancelReservationPending != null) {
            builder.addAction(0, "하차 예약 취소", cancelReservationPending);
        }
        // 화면 표시 여부와 관계없이 시스템 알림 채널의 음량·소리·진동 설정을 따릅니다.
        // 설정한 재생 시간이 끝나면 소리·진동과 알림 카드를 함께 제거합니다.

        try {
            if (playSound) stopAlertPlayback();
            Notification notification = builder.build();
            if (postNotification) NotificationManagerCompat.from(context).notify(STOP_NOTIFICATION_ID, notification);
            if (playSound && NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                boolean allowSound = true;
                boolean allowVibration = true;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    NotificationManager manager = context.getSystemService(NotificationManager.class);
                    NotificationChannel configuredChannel = manager == null
                            ? null
                            : manager.getNotificationChannel(channel);
                    if (configuredChannel != null) {
                        allowSound = configuredChannel.getImportance() != NotificationManager.IMPORTANCE_NONE
                                && configuredChannel.getSound() != null;
                        allowVibration = configuredChannel.getImportance() != NotificationManager.IMPORTANCE_NONE
                                && configuredChannel.shouldVibrate();
                    }
                }
                if (allowSound || allowVibration) {
                    startAlertPlayback(context, sound, alertDuration, allowSound, allowVibration);
                }
            }
            return notification;
        } catch (SecurityException ignored) {
            // Android 13+ 알림 권한을 거부한 경우 앱 화면 알림은 계속 동작합니다.
            return builder.build();
        }
    }

    static synchronized void startAlertPlayback(
            Context context,
            String sound,
            int durationSeconds,
            boolean allowSound,
            boolean allowVibration
    ) {
        Context appContext = context.getApplicationContext();
        alertContext = appContext;
        int duration = Math.max(5, Math.min(durationSeconds, 60));
        int firstSoundDurationMs = soundDurationMs(sound);
        int soundResource = soundResource(sound);
        long[] vibrationPattern = vibration(sound);

        // 알림 채널이 첫 음원과 첫 진동을 재생한 뒤, 남은 설정 시간 동안
        // 같은 전용음을 알림 음량으로 반복합니다.
        startRepeatRunnable = () -> {
            synchronized (BumatiNotifications.class) {
                if (allowSound) {
                    try {
                        Uri soundUri = Uri.parse(ContentResolver.SCHEME_ANDROID_RESOURCE
                                + "://" + appContext.getPackageName() + "/" + soundResource);
                        MediaPlayer player = new MediaPlayer();
                        alertPlayer = player;
                        player.setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build());
                        player.setDataSource(appContext, soundUri);
                        player.setLooping(true);
                        player.prepare();
                        player.start();
                        alertPlayer = player;
                    } catch (Exception error) {
                        android.util.Log.w("BUMATI", "반복 알림음 재생 실패", error);
                        if (alertPlayer != null) alertPlayer.release();
                        alertPlayer = null;
                    }
                }

                if (allowVibration) {
                    Vibrator vibrator = (Vibrator) appContext.getSystemService(Context.VIBRATOR_SERVICE);
                    if (vibrator != null && vibrator.hasVibrator()) {
                        vibrator.vibrate(VibrationEffect.createWaveform(vibrationPattern, 0),
                                new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION)
                                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
                        alertVibrator = vibrator;
                    }
                }
            }
        };
        String playbackToken = activeToken;
        stopAlertRunnable = () -> dismiss(appContext, playbackToken);
        ALERT_HANDLER.postDelayed(startRepeatRunnable, Math.min(firstSoundDurationMs, duration * 1000L));
        ALERT_HANDLER.postDelayed(stopAlertRunnable, duration * 1000L);
    }

    static synchronized void stopAlertPlayback() {
        if (startRepeatRunnable != null) ALERT_HANDLER.removeCallbacks(startRepeatRunnable);
        if (stopAlertRunnable != null) ALERT_HANDLER.removeCallbacks(stopAlertRunnable);
        startRepeatRunnable = null;
        stopAlertRunnable = null;
        if (alertPlayer != null) {
            try { alertPlayer.stop(); } catch (Exception ignored) {}
            alertPlayer.release();
            alertPlayer = null;
        }
        if (alertVibrator != null) {
            alertVibrator.cancel();
            alertVibrator = null;
        }
        if (alertContext != null) {
            NotificationManagerCompat.from(alertContext).cancel(STOP_NOTIFICATION_ID);
            alertContext = null;
        }
    }

    private static String alertChannel(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return ALERT_CHANNEL_GENTLE;
        if ("urgent".equalsIgnoreCase(sound)) return ALERT_CHANNEL_URGENT;
        return ALERT_CHANNEL_CLASSIC;
    }

    private static int soundResource(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return R.raw.bumati_gentle;
        if ("urgent".equalsIgnoreCase(sound)) return R.raw.bumati_urgent;
        return R.raw.bumati_classic;
    }

    private static int soundDurationMs(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return 1380;
        if ("urgent".equalsIgnoreCase(sound)) return 1400;
        return 1300;
    }

    private static long[] vibration(String sound) {
        if ("gentle".equalsIgnoreCase(sound)) return new long[]{0, 420, 260, 420};
        if ("urgent".equalsIgnoreCase(sound)) return new long[]{0, 260, 90, 260, 90, 420};
        return new long[]{0, 320, 110, 320, 260};
    }
}
