package com.bumati.app;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import androidx.annotation.Nullable;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;

public class BumatiReservationService extends Service {
    static final String ACTION_START = "com.bumati.app.action.START_RESERVATION_WATCH";
    static final String ACTION_STOP = "com.bumati.app.action.STOP_RESERVATION_WATCH";
    private static final String EXTRA_KEY = "reservation_key";
    private static final String EXTRA_STOP = "stop_name";
    private static final String EXTRA_SOUND = "alert_sound";
    private static final String EXTRA_DURATION = "alert_duration";
    private static final String PREFS = "bumati_reservation_service";
    private static final String FIREBASE_RESERVATIONS_URL =
            "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app/radar/reservations/";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicInteger generation = new AtomicInteger();
    private Future<?> worker;
    private String activeReservationKey = "";

    static void start(Context context, String key, String stopName, String sound, int durationSeconds) {
        if (key == null || key.trim().isEmpty()) return;
        Intent intent = new Intent(context, BumatiReservationService.class)
                .setAction(ACTION_START)
                .putExtra(EXTRA_KEY, key)
                .putExtra(EXTRA_STOP, stopName)
                .putExtra(EXTRA_SOUND, sound)
                .putExtra(EXTRA_DURATION, durationSeconds);
        ContextCompat.startForegroundService(context, intent);
    }

    static void stop(Context context) {
        Intent intent = new Intent(context, BumatiReservationService.class).setAction(ACTION_STOP);
        context.startService(intent);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        BumatiNotifications.createChannels(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            clearSavedReservation();
            stopWatching();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }

        String key = intent == null ? null : intent.getStringExtra(EXTRA_KEY);
        String stopName = intent == null ? null : intent.getStringExtra(EXTRA_STOP);
        String sound = intent == null ? null : intent.getStringExtra(EXTRA_SOUND);
        int duration = intent == null ? 0 : intent.getIntExtra(EXTRA_DURATION, 15);

        if (key == null || key.trim().isEmpty()) {
            key = getSharedPreferences(PREFS, 0).getString(EXTRA_KEY, "");
            stopName = getSharedPreferences(PREFS, 0).getString(EXTRA_STOP, "예약 정류장");
            sound = getSharedPreferences(PREFS, 0).getString(EXTRA_SOUND, "classic");
            duration = getSharedPreferences(PREFS, 0).getInt(EXTRA_DURATION, 15);
        }
        if (key == null || key.trim().isEmpty()) {
            stopSelf();
            return START_NOT_STICKY;
        }

        stopName = stopName == null || stopName.trim().isEmpty() ? "예약 정류장" : stopName;
        sound = sound == null || sound.trim().isEmpty() ? "classic" : sound;
        duration = Math.max(5, Math.min(duration, 60));
        saveReservation(key, stopName, sound, duration);

        int foregroundType = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                ? ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                : 0;
        ServiceCompat.startForeground(
                this,
                BumatiNotifications.WATCH_NOTIFICATION_ID,
                BumatiNotifications.buildWatchNotification(this, stopName).build(),
                foregroundType
        );

        if (key.equals(activeReservationKey) && worker != null && !worker.isDone()) {
            return START_STICKY;
        }

        activeReservationKey = key;
        int currentGeneration = generation.incrementAndGet();
        if (worker != null) worker.cancel(true);
        String finalKey = key;
        String finalStopName = stopName;
        String finalSound = sound;
        int finalDuration = duration;
        worker = executor.submit(() -> watchReservation(
                currentGeneration,
                finalKey,
                finalStopName,
                finalSound,
                finalDuration
        ));
        return START_STICKY;
    }

    private void watchReservation(int expectedGeneration, String key, String stopName, String sound, int duration) {
        while (!Thread.currentThread().isInterrupted() && generation.get() == expectedGeneration) {
            HttpURLConnection connection = null;
            try {
                String encodedKey = android.net.Uri.encode(key);
                connection = (HttpURLConnection) new java.net.URL(
                        FIREBASE_RESERVATIONS_URL + encodedKey + ".json"
                ).openConnection();
                connection.setRequestMethod("GET");
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                connection.setUseCaches(false);

                int responseCode = connection.getResponseCode();
                if (responseCode >= 200 && responseCode < 300) {
                    String body;
                    try (BufferedReader reader = new BufferedReader(
                            new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8))) {
                        StringBuilder result = new StringBuilder();
                        String line;
                        while ((line = reader.readLine()) != null) result.append(line);
                        body = result.toString();
                    }

                    if (body.trim().isEmpty() || "null".equals(body)) {
                        finishWatch(expectedGeneration, false, stopName, sound, duration);
                        return;
                    }
                    JSONObject reservation = new JSONObject(body);
                    String status = reservation.optString("status", "pending");
                    if ("triggered".equalsIgnoreCase(status)) {
                        String targetName = reservation.optString("targetStopName", stopName);
                        String targetSound = reservation.optString("alertSound", sound);
                        int targetDuration = reservation.optInt("alertDurationSeconds", duration);
                        finishWatch(expectedGeneration, true, targetName, targetSound, targetDuration);
                        return;
                    }
                    if (!"pending".equalsIgnoreCase(status)) {
                        finishWatch(expectedGeneration, false, stopName, sound, duration);
                        return;
                    }
                }
                Thread.sleep(1000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception ignored) {
                try {
                    Thread.sleep(3000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return;
                }
            } finally {
                if (connection != null) connection.disconnect();
            }
        }
    }

    private void finishWatch(
            int expectedGeneration,
            boolean triggered,
            String stopName,
            String sound,
            int duration
    ) {
        if (generation.get() != expectedGeneration) return;
        clearSavedReservation();
        if (triggered) {
            BumatiNotifications.postStopAlert(
                    this,
                    "🔔 BUMATI 하차 알림",
                    "하차벨이 울렸습니다. " + stopName + "에서 하차하세요.",
                    sound,
                    duration,
                    true
            );
        }
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void saveReservation(String key, String stopName, String sound, int duration) {
        getSharedPreferences(PREFS, 0).edit()
                .putString(EXTRA_KEY, key)
                .putString(EXTRA_STOP, stopName)
                .putString(EXTRA_SOUND, sound)
                .putInt(EXTRA_DURATION, duration)
                .apply();
    }

    private void clearSavedReservation() {
        getSharedPreferences(PREFS, 0).edit().clear().apply();
        activeReservationKey = "";
    }

    private void stopWatching() {
        generation.incrementAndGet();
        if (worker != null) worker.cancel(true);
        worker = null;
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        clearSavedReservation();
        stopWatching();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf(startId);
    }

    @Override
    public void onDestroy() {
        stopWatching();
        executor.shutdownNow();
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
