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
    private android.net.wifi.WifiManager.WifiLock wifiLock;
    private boolean powerReceiverRegistered;
    private final android.content.BroadcastReceiver powerReceiver = new android.content.BroadcastReceiver() {
        @Override public void onReceive(android.content.Context context, Intent intent) {
            String action = intent.getAction();
            String event = Intent.ACTION_SCREEN_ON.equals(action) ? "SCREEN_ON"
                : Intent.ACTION_SCREEN_OFF.equals(action) ? "SCREEN_OFF"
                : Intent.ACTION_USER_PRESENT.equals(action) ? "USER_PRESENT"
                : PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED.equals(action) ? "DEVICE_IDLE_CHANGED"
                : PowerManager.ACTION_POWER_SAVE_MODE_CHANGED.equals(action) ? "POWER_SAVE_CHANGED" : null;
            if (event != null) recordPower(event);
        }
    };
    private final Runnable diagnosticTick = new Runnable() {
        @Override public void run() {
            recordPower("SERVICE_HEARTBEAT");
            wakeHandler.postDelayed(this, 30_000);
        }
    };
    private void recordPower(String event) {
        AndroidDiagnostics.event(this, event,
            "running=" + running + " " + AndroidDiagnostics.power(this,
                lock != null && lock.isHeld(), wifiLock != null && wifiLock.isHeld()));
    }
    private final Runnable renewLock = new Runnable() {
        @Override public void run() {
            if (!running || !getSharedPreferences(PREFS, MODE_PRIVATE)
                    .getBoolean(KEEP_AWAKE, true)) return;
            if (lock != null) {
                lock.acquire(WAKELOCK_TIMEOUT);
                recordPower("CPU_LOCK_RENEWED");
                wakeHandler.postDelayed(this, WAKELOCK_RENEWAL);
            }
        }
    };
    public static volatile boolean running = false;
    public static volatile String lastState = "未启动";
    private static final List<String> history = new ArrayList<>();
    private TelephonyManager telephonyManager;
    private PhoneEventBridge bridge;
    private static volatile PhoneEventBridge activeAnswerBridge;
    private static volatile CallMonitorService activeMonitor;
    private TelephonyCallback telephonyCallback;
    private java.util.concurrent.ExecutorService callStateExecutor;
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
        AndroidDiagnostics.init(this);
        recordPower("SERVICE_CREATE");
        android.content.IntentFilter filter = new android.content.IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_USER_PRESENT);
        filter.addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED);
        filter.addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED);
        try {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(powerReceiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED);
            else registerReceiver(powerReceiver, filter);
            powerReceiverRegistered = true;
        } catch (Exception error) {
            AndroidDiagnostics.event(this, "POWER_RECEIVER_FAILED", "error=" + error.getClass().getSimpleName());
        }
        wakeHandler.postDelayed(diagnosticTick, 30_000);
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL,
                "电话状态监听", NotificationManager.IMPORTANCE_LOW));
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        AndroidDiagnostics.event(this, "SERVICE_START", "flags=" + flags + " startId=" + startId);
        if (!getSharedPreferences("simai_initial_setup", MODE_PRIVATE)
                .getBoolean("phone_state_monitor_desired", true)) {
            AndroidDiagnostics.event(this, "SERVICE_USER_DISABLED", "");
            stopSelf(); return START_NOT_STICKY;
        }
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            lastState = "缺少电话状态权限";
            note("权限不足，监听服务未启动");
            AndroidDiagnostics.event(this, "SERVICE_PERMISSION_MISSING", "");
            stopSelf();
            return START_NOT_STICKY;
        }
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setContentTitle("SIM AI Companion")
                .setContentText("正在观察电话状态（无录音、无来电号码）")
                .setSmallIcon(android.R.drawable.ic_menu_call)
                .setOngoing(true)
                .build();
        try {
            startForeground(90, notification);
            recordPower("FOREGROUND_STARTED");
        } catch (Exception error) {
            AndroidDiagnostics.event(this, "FOREGROUND_FAILED", "error=" + error.getClass().getSimpleName());
            stopSelf(); return START_NOT_STICKY;
        }
        if (!running) {
            try {
                bridge = new PhoneEventBridge(this);
                bridge.start();
                activeAnswerBridge = bridge;
                telephonyManager = (TelephonyManager) getSystemService(TELEPHONY_SERVICE);
                if (telephonyManager == null) throw new IllegalStateException("TelephonyManager unavailable");
                lastState = "UNKNOWN";
                int initialState = telephonyManager.getCallState();
                // A protected PHONE_STATE wake can arrive before the vendor's
                // aggregate getCallState() cache catches up. Only consume a
                // very recent broadcast, never an old sticky restart intent.
                if (intent != null) {
                    long eventAt = intent.getLongExtra("system_phone_state_elapsed", -1);
                    long age = android.os.SystemClock.elapsedRealtime() - eventAt;
                    int fromBroadcast = intent.getIntExtra("system_phone_state", -1);
                    if (eventAt >= 0 && age >= 0 && age <= 5000 &&
                        (fromBroadcast == TelephonyManager.CALL_STATE_RINGING ||
                         fromBroadcast == TelephonyManager.CALL_STATE_OFFHOOK ||
                         fromBroadcast == TelephonyManager.CALL_STATE_IDLE)) {
                        initialState = fromBroadcast;
                    }
                }
                handleState(initialState);
                if (Build.VERSION.SDK_INT >= 31) {
                    StateCallback callback = new StateCallback();
                    telephonyCallback = callback;
                    callStateExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
                    telephonyManager.registerTelephonyCallback(callStateExecutor, callback);
                } else {
                    legacyListener = new PhoneStateListener() {
                        @Override public void onCallStateChanged(int state, String ignoredIncomingNumber) {
                            // Deliberately never inspect/store/forward the phone number.
                            handleState(state);
                        }
                    };
                    telephonyManager.listen(legacyListener, PhoneStateListener.LISTEN_CALL_STATE);
                }
                activeMonitor = this;
                running = true;
                applyKeepAwakeSetting();
                note("监听已启动，等待实际来电");
                recordPower("MONITOR_READY");
            } catch (Exception error) {
                note("监听启动失败：" + error.getClass().getSimpleName());
                AndroidDiagnostics.event(this, "MONITOR_INIT_FAILED", "error=" + error.getClass().getSimpleName());
                lastState = "监听初始化失败";
                activeAnswerBridge = null;
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
            AndroidDiagnostics.event(this, "CPU_LOCK_FAILED", "error=" + failed.getClass().getSimpleName());
            releaseWakeLock();
        }
        try {
            if (wifiLock == null) {
                android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
                if (wm != null) {
                    // LOW_LATENCY applies only under foreground/screen-on conditions on Android 13.
                    int mode = android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF;
                    wifiLock = wm.createWifiLock(mode, "SIMAI:CompanionWiFiLock");
                    wifiLock.setReferenceCounted(false);
                }
            }
            if (wifiLock != null && !wifiLock.isHeld()) {
                wifiLock.acquire();
            }
        } catch (Exception e) {
            note("Wi-Fi 后台常驻锁异常：" + e.getClass().getSimpleName());
            AndroidDiagnostics.event(this, "WIFI_LOCK_FAILED", "error=" + e.getClass().getSimpleName());
        }
    }

    private void releaseWakeLock() {
        wakeHandler.removeCallbacks(renewLock);
        if (lock != null) {
            if (lock.isHeld()) lock.release();
            lock = null;
        }
        if (wifiLock != null) {
            try {
                if (wifiLock.isHeld()) wifiLock.release();
            } catch (Exception ignored) {}
            wifiLock = null;
        }
    }

    private synchronized void handleState(int state) {
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
            AndroidDiagnostics.event(this, "CALL_STATE", "state=" + next);
            if (bridge != null) bridge.recordState(next);
        }
    }

    static void deliverSystemPhoneState(int state) {
        CallMonitorService monitor = activeMonitor;
        if (monitor != null && running) monitor.handleState(state);
    }

    private final class StateCallback extends TelephonyCallback implements TelephonyCallback.CallStateListener {
        @Override public void onCallStateChanged(int state) { handleState(state); }
    }

    static String requestGuardedAnswerFromADB(String session, int sequence) {
        PhoneEventBridge bridge = activeAnswerBridge;
        if (bridge == null || !running) return "MONITOR_INACTIVE";
        return bridge.acceptAndRecordGuardedShellRequest(session, sequence);
    }

    @Override public void onTaskRemoved(Intent rootIntent) {
        recordPower("TASK_REMOVED");
        super.onTaskRemoved(rootIntent);
    }
    @Override public void onTrimMemory(int level) {
        AndroidDiagnostics.event(this, "TRIM_MEMORY", "level=" + level);
        super.onTrimMemory(level);
    }
    @Override public void onDestroy() {
        recordPower("SERVICE_DESTROY");
        wakeHandler.removeCallbacks(diagnosticTick);
        if (powerReceiverRegistered) {
            try { unregisterReceiver(powerReceiver); } catch (Exception ignored) {}
        }
        activeMonitor = null;
        activeAnswerBridge = null;
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
        if (callStateExecutor != null) callStateExecutor.shutdownNow();
        running = false;
        lastState = "已停止";
        note("监听停止");
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
