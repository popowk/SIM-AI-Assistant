package com.popowk.simai.companion;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.Handler;
import android.os.Looper;
import android.telephony.PhoneStateListener;
import android.telephony.TelephonyCallback;
import android.telephony.TelephonyManager;
import android.util.Log;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Explicit opt-in, foreground-only cellular call STATE monitor.
 * No phone numbers, recordings, privileged audio or answering APIs.
 */
public final class CallMonitorService extends Service {
    private static final String CHANNEL = "sim_ai_phone_monitor";
    public static final String PREFS = "simai_monitor_preferences";
    public static final String KEEP_AWAKE = "keep_cpu_awake_for_lock_screen_sync";
    private static final long WAKELOCK_TIMEOUT = 20L * 60 * 1000;
    private static final long WAKELOCK_RENEWAL = 15L * 60 * 1000;
    private final Handler wakeHandler = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock lock;
    private final Runnable renewLock = new Runnable() {
        @Override public void run() {
            if (!running || !getSharedPreferences(PREFS, MODE_PRIVATE)
                    .getBoolean(KEEP_AWAKE, true)) return;
            if (lock != null) {
                lock.acquire(WAKELOCK_TIMEOUT);
                wakeHandler.postDelayed(this, WAKELOCK_RENEWAL);
            }
        }
    };
    public static volatile boolean running = false;
    public static volatile String lastState = "未启动";
    private static final List<String> history = new ArrayList<>();
    private TelephonyManager telephonyManager;
    private PhoneEventBridge bridge;
    private TelephonyCallback telephonyCallback;
    private PhoneStateListener legacyListener;

    public static synchronized List<String> eventSnapshot() {
        return new ArrayList<>(history);
    }

    public static synchronized void note(String message) {
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.CHINA).format(new Date());
        history.add(stamp + "  " + message);
        while (history.size() > 40) history.remove(0);
        Log.i("SIMAICompanion", message);
    }

    @Override public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL,
                "电话状态监听", NotificationManager.IMPORTANCE_LOW));
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            lastState = "缺少电话状态权限";
            note("权限不足，监听服务未启动");
            stopSelf();
            return START_NOT_STICKY;
        }
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setContentTitle("SIM AI Companion")
                .setContentText("正在观察电话状态（无录音、无来电号码）")
                .setSmallIcon(android.R.drawable.ic_menu_call)
                .setOngoing(true)
                .build();
        startForeground(90, notification);
        if (!running) {
            try {
                bridge = new PhoneEventBridge(this);
                bridge.start();
                telephonyManager = (TelephonyManager) getSystemService(TELEPHONY_SERVICE);
                if (telephonyManager == null) throw new IllegalStateException("TelephonyManager unavailable");
                if (Build.VERSION.SDK_INT >= 31) {
                    StateCallback callback = new StateCallback();
                    telephonyCallback = callback;
                    telephonyManager.registerTelephonyCallback(getMainExecutor(), callback);
                } else {
                    legacyListener = new PhoneStateListener() {
                        @Override public void onCallStateChanged(int state, String ignoredIncomingNumber) {
                            // Deliberately never inspect/store/forward the phone number.
                            handleState(state);
                        }
                    };
                    telephonyManager.listen(legacyListener, PhoneStateListener.LISTEN_CALL_STATE);
                }
                running = true;
                applyKeepAwakeSetting();
                handleState(telephonyManager.getCallState());
                note("监听已启动，等待实际来电");
            } catch (Exception error) {
                note("监听启动失败：" + error.getClass().getSimpleName());
                lastState = "监听初始化失败";
                if (bridge != null) { bridge.stop(); bridge = null; }
                stopSelf();
            }
        }
        // User explicitly started a foreground monitor. Allow a system-requested
        // service restart after memory pressure; does not override force-stop or
        // vendor background restrictions.
        if (running) applyKeepAwakeSetting();
        return START_STICKY;
    }

    private void applyKeepAwakeSetting() {
        wakeHandler.removeCallbacks(renewLock);
        boolean requested = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(KEEP_AWAKE, true);
        if (!requested) {
            releaseWakeLock();
            return;
        }
        try {
            if (lock == null) {
                PowerManager manager = getSystemService(PowerManager.class);
                lock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SIMAI:PhoneStateBridge");
                lock.setReferenceCounted(false);
            }
            lock.acquire(WAKELOCK_TIMEOUT);
            wakeHandler.postDelayed(renewLock, WAKELOCK_RENEWAL);
        } catch (Exception failed) {
            note("锁屏运行增强不可用：" + failed.getClass().getSimpleName());
            releaseWakeLock();
        }
    }

    private void releaseWakeLock() {
        wakeHandler.removeCallbacks(renewLock);
        if (lock != null) {
            if (lock.isHeld()) lock.release();
            lock = null;
        }
    }

    private void handleState(int state) {
        String next;
        switch (state) {
            case TelephonyManager.CALL_STATE_RINGING: next = "RINGING"; break;
            case TelephonyManager.CALL_STATE_OFFHOOK: next = "OFFHOOK"; break;
            case TelephonyManager.CALL_STATE_IDLE: next = "IDLE"; break;
            default: next = "UNKNOWN"; break;
        }
        if (!next.equals(lastState)) {
            lastState = next;
            note("电话状态：" + next);
            if (bridge != null) bridge.recordState(next);
        }
    }

    private final class StateCallback extends TelephonyCallback implements TelephonyCallback.CallStateListener {
        @Override public void onCallStateChanged(int state) { handleState(state); }
    }

    @Override public void onDestroy() {
        releaseWakeLock();
        if (bridge != null) { bridge.stop(); bridge = null; }
        if (telephonyManager != null) {
            try {
                if (Build.VERSION.SDK_INT >= 31 && telephonyCallback != null)
                    telephonyManager.unregisterTelephonyCallback(telephonyCallback);
                else if (legacyListener != null)
                    telephonyManager.listen(legacyListener, PhoneStateListener.LISTEN_NONE);
            } catch (Exception ignored) { }
        }
        running = false;
        lastState = "已停止";
        note("监听停止");
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
