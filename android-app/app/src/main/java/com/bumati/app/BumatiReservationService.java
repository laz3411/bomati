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
    static final String ACTION_CANCEL = "com.bumati.app.action.CANCEL_RESERVATION";
    private static final String EXTRA_KEY = "reservation_key";
    private static final String EXTRA_STOP = "stop_name";
    private static final String EXTRA_SOUND = "alert_sound";
    private static final String EXTRA_DURATION = "alert_duration";
    private static final String PREFS = "bumati_reservation_service";
    private static final String FIREBASE_RESERVATIONS_URL =
            "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app/radar/reservations/";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final ExecutorService cancelWorker = Executors.newSingleThreadExecutor();
    private final AtomicInteger generation = new AtomicInteger();
    private Future<?> worker;
    private String activeReservationKey = "";
    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private String currentStamp = "";
    private String activeAlertToken = "";

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
            BumatiNotifications.dismiss(this, null);
            clearSavedReservation();
            stopWatching();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent != null && ACTION_CANCEL.equals(intent.getAction())) {
            String cancelKey = intent.getStringExtra("key");
            String cancelStamp = intent.getStringExtra("stamp");
            if (cancelKey != null && cancelStamp != null) {
                cancelWorker.submit(() -> cancelReservation(cancelKey, cancelStamp));
            }
            if (!activeReservationKey.isEmpty()) return START_STICKY;
            // 알림 버튼으로 프로세스가 다시 시작된 경우에도 저장된 감시를 복원합니다.
            intent = null;
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

        if (!key.equals(activeReservationKey)) currentStamp = "";
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
                BumatiNotifications.buildWatchNotification(this, stopName, key, currentStamp).build(),
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
                    if (hasDisembarked(key, reservation)) {
                        cancelReservation(key, reservation.optString("reservedAt", "0"));
                        Thread.sleep(1000);
                        continue;
                    }
                    if ("triggered".equalsIgnoreCase(status)) {
                        String targetName = reservation.optString("targetStopName", stopName);
                        String targetSound = reservation.optString("alertSound", sound);
                        int targetDuration = reservation.optInt("alertDurationSeconds", duration);
                        String stamp = reservation.optString("reservedAt", "0");
                        main.post(() -> {
                            if (generation.get() != expectedGeneration) return;
                            currentStamp = stamp;
                            String alertToken = key + "@" + stamp;
                            if (alertToken.equals(activeAlertToken)) return;
                            android.app.Notification alertNotification = BumatiNotifications.postReservationAlert(
                                    this, alertToken, targetName, targetSound, targetDuration);
                            if (alertNotification == null) {
                                // 이미 처리한 도착 알림을 서비스 재시작으로 다시 표시하지 않습니다.
                                clearSavedReservation();
                                stopWatching();
                                stopForeground(STOP_FOREGROUND_REMOVE);
                                stopSelf();
                                return;
                            }
                            activeAlertToken = alertToken;
                            int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                                    ? ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                                    : 0;
                            // 예약 대기 알림을 같은 ID의 도착 알림으로 교체해 두 알림이 겹치지 않게 합니다.
                            ServiceCompat.startForeground(
                                    this,
                                    BumatiNotifications.WATCH_NOTIFICATION_ID,
                                    alertNotification,
                                    type
                            );
                        });
                    }
                    String stamp = reservation.optString("reservedAt", "0");
                    if ("pending".equalsIgnoreCase(status)) {
                        main.post(() -> {
                            if (generation.get() != expectedGeneration) return;
                            currentStamp = stamp;
                            try {
                                androidx.core.app.NotificationManagerCompat.from(this).notify(
                                    BumatiNotifications.WATCH_NOTIFICATION_ID,
                                    BumatiNotifications.buildWatchNotification(this,
                                        reservation.optString("targetStopName", stopName), key, stamp).build());
                            } catch (SecurityException ignored) {
                                // 알림 권한이 없어도 예약 확인은 계속합니다.
                            }
                        });
                    }
                    if (!"pending".equalsIgnoreCase(status) && !"triggered".equalsIgnoreCase(status)) {
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
        main.post(() -> {
            if (generation.get() != expectedGeneration) return;
            clearSavedReservation();
            BumatiNotifications.dismiss(this, null);
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        });
    }

    private void saveReservation(String key, String stopName, String sound, int duration) {
        getSharedPreferences(PREFS, 0).edit()
                .putString(EXTRA_KEY, key)
                .putString(EXTRA_STOP, stopName)
                .putString(EXTRA_SOUND, sound)
                .putInt(EXTRA_DURATION, duration)
                .apply();
    }

    private boolean hasDisembarked(String key, JSONObject reservation) {
        // 위치가 아닌 서버의 실제 탑승 판정만 사용하며 통신 실패/오래된 값으로 취소하지 않습니다.
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new java.net.URL(
                    "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app/radar/bell.json").openConnection();
            connection.setConnectTimeout(3000);
            connection.setReadTimeout(3000);
            connection.setUseCaches(false);
            if (connection.getResponseCode() != 200) return false;
            StringBuilder body = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) body.append(line);
            }
            JSONObject bell = new JSONObject(body.toString());
            long age = System.currentTimeMillis() - bell.optLong("timestamp", 0);
            if (age < -5000 || age > 10000) return false;
            String token = key + "@" + reservation.optString("reservedAt", "0");
            boolean active = bell.optBoolean("active", false);
            String vehicle = reservation.optString("vehicleNumber", "");
            String boardedVehicle = bell.optString("vehicleNumber", "");
            boolean sameBus = !vehicle.isEmpty() || !boardedVehicle.isEmpty()
                    ? !vehicle.isEmpty() && vehicle.equals(boardedVehicle)
                        && reservation.optString("route").equals(bell.optString("route"))
                    : reservation.optString("busId").equals(bell.optString("busId"));
            if (active && sameBus) {
                getSharedPreferences(PREFS, 0).edit().putString("boarded_token", token).apply();
                return false;
            }
            return token.equals(getSharedPreferences(PREFS, 0).getString("boarded_token", ""))
                    && (bell.has("active") && !active || bell.optBoolean("canImmediateExit", false) && !sameBus);
        } catch (Exception ignored) {
            return false;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private void cancelReservation(String key, String stamp) {
        HttpURLConnection connection = null;
        try {
            String url = FIREBASE_RESERVATIONS_URL + android.net.Uri.encode(key) + ".json";
            connection = (HttpURLConnection) new java.net.URL(url).openConnection();
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(5000);
            connection.setRequestProperty("X-Firebase-ETag", "true");
            if (connection.getResponseCode() != 200) throw new Exception("예약 조회 실패");
            StringBuilder body = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) body.append(line);
            }
            String etag = connection.getHeaderField("ETag");
            if (!"null".equals(body.toString().trim())) {
                JSONObject reservation = new JSONObject(body.toString());
                String liveStamp = reservation.optString("reservedAt", "0");
                boolean activeServiceReservation = key.equals(activeReservationKey);
                if ((!stamp.isEmpty() || !activeServiceReservation) && !stamp.equals(liveStamp)) {
                    throw new Exception("예약이 변경되었습니다. 앱에서 확인하세요.");
                }
                if (etag == null) throw new Exception("예약 버전 확인 실패");
                connection.disconnect();
                connection = (HttpURLConnection) new java.net.URL(url).openConnection();
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                connection.setRequestMethod("PUT");
                connection.setRequestProperty("if-match", etag);
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setDoOutput(true);
                try (java.io.OutputStream stream = connection.getOutputStream()) { stream.write("null".getBytes(StandardCharsets.UTF_8)); }
                int code = connection.getResponseCode();
                if (code < 200 || code >= 300) throw new Exception("예약 취소 실패. 다시 시도해 주세요.");
            }
            main.post(() -> {
                if (key.equals(activeReservationKey) && stamp.equals(currentStamp)) {
                    BumatiNotifications.dismiss(this, key + "@" + stamp);
                    clearSavedReservation();
                    stopWatching();
                    stopForeground(STOP_FOREGROUND_REMOVE);
                    stopSelf();
                }
            });
        } catch (Exception error) {
            android.util.Log.w("BUMATI", "알림에서 예약 취소 실패", error);
            main.post(() -> android.widget.Toast.makeText(this, error.getMessage(), android.widget.Toast.LENGTH_LONG).show());
        } finally { if (connection != null) connection.disconnect(); }
    }

    private void clearSavedReservation() {
        getSharedPreferences(PREFS, 0).edit().clear().apply();
        activeReservationKey = "";
        activeAlertToken = "";
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
        main.removeCallbacksAndMessages(null);
        BumatiNotifications.stopAlertPlayback();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopWatching();
        executor.shutdownNow();
        cancelWorker.shutdownNow();
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
