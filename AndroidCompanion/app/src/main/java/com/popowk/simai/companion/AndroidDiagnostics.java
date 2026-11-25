package com.popowk.simai.companion;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.app.KeyguardManager;
import android.content.Context;
import android.os.Build;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/** Small private, rotating, content-free diagnostics. No phone numbers,
 * audio, SMS, IP, tokens, raw exceptions or other apps' logcat. */
final class AndroidDiagnostics {
    private static final long MAX_BYTES = 64 * 1024;
    private static final AtomicBoolean initialized = new AtomicBoolean();
    private static final String TAG = "SIMAI-Diagnostics";

    static void init(Context context) {
        if (!initialized.compareAndSet(false, true)) return;
        Context app = context.getApplicationContext();
        String version = "unknown";
        try { version = app.getPackageManager().getPackageInfo(app.getPackageName(), 0).versionName; }
        catch (Exception ignored) {}
        event(app, "PROCESS_START", "sdk=" + Build.VERSION.SDK_INT + " version=" + safe(version));
        if (Build.VERSION.SDK_INT >= 30) {
            Thread worker = new Thread(() -> {
                try {
                    ActivityManager am = app.getSystemService(ActivityManager.class);
                    if (am == null) return;
                    for (ApplicationExitInfo e : am.getHistoricalProcessExitReasons(null, 0, 5)) {
                        recordPreviousExit(app, e);
                    }
                } catch (Exception failure) {
                    event(app, "EXIT_HISTORY_UNAVAILABLE", "error=" + failure.getClass().getSimpleName());
                }
            }, "SIMAI-ExitHistory");
            worker.setDaemon(true);
            worker.start();
        }
    }
    // Serialize with clear() so a queued exit-history scan cannot restore
    // entries that predate an explicitly requested clear.
    private static synchronized void recordPreviousExit(Context app, ApplicationExitInfo e) {
        android.content.SharedPreferences prefs = app.getSharedPreferences("simai_diagnostic_meta", Context.MODE_PRIVATE);
        if (e.getTimestamp() <= prefs.getLong("clearedAt", 0)) return;
        event(app, "PREVIOUS_EXIT", "reason=" + e.getReason() +
                " status=" + e.getStatus() + " importance=" + e.getImportance() +
                " exitWallMs=" + e.getTimestamp());
    }

    static synchronized boolean clear(Context context) {
        File current = new File(context.getFilesDir(), "phone-diagnostics.jsonl");
        File previous = new File(context.getFilesDir(), "phone-diagnostics.previous.jsonl");
        boolean currentOK = !current.exists() || current.delete();
        boolean previousOK = !previous.exists() || previous.delete();
        if (!currentOK || !previousOK || current.exists() || previous.exists()) return false;
        return context.getSharedPreferences("simai_diagnostic_meta", Context.MODE_PRIVATE)
                .edit().putLong("clearedAt", System.currentTimeMillis()).commit();
    }

    static synchronized String recent(Context context) {
        StringBuilder out = new StringBuilder();
        File current = new File(context.getFilesDir(), "phone-diagnostics.jsonl");
        if (!current.exists()) return "暂无新日志";
        try (java.io.BufferedReader reader = new java.io.BufferedReader(
                new java.io.InputStreamReader(new java.io.FileInputStream(current), StandardCharsets.UTF_8))) {
            java.util.ArrayDeque<String> lines = new java.util.ArrayDeque<>();
            String line;
            while ((line = reader.readLine()) != null) {
                lines.addLast(line);
                if (lines.size() > 100) lines.removeFirst();
            }
            for (String item : lines) out.append(item).append('\n');
            return out.toString();
        } catch (Exception e) { return "读取手机日志失败"; }
    }

    private static String safe(String value) {
        if (value == null || !value.matches("[A-Za-z0-9_.-]{1,80}")) return "unknown";
        return value;
    }
    static String power(Context context, boolean cpuLock, boolean wifiLock) {
        try {
            PowerManager pm = context.getSystemService(PowerManager.class);
            KeyguardManager km = context.getSystemService(KeyguardManager.class);
            ActivityManager am = context.getSystemService(ActivityManager.class);
            if (pm == null) return "error=PowerManagerUnavailable";
            return "interactive=" + pm.isInteractive() +
                   " locked=" + (km != null && km.isKeyguardLocked()) +
                   " idle=" + pm.isDeviceIdleMode() +
                   " powerSave=" + pm.isPowerSaveMode() +
                   " ignoreBatteryOpt=" + pm.isIgnoringBatteryOptimizations(context.getPackageName()) +
                   " backgroundRestricted=" + (Build.VERSION.SDK_INT >= 28 && am != null && am.isBackgroundRestricted()) +
                   " cpuLock=" + cpuLock + " wifiLock=" + wifiLock;
        } catch (Exception error) { return "error=" + error.getClass().getSimpleName(); }
    }
    static synchronized void event(Context context, String name, String fields) {
        if (context == null || name == null || !name.matches("[A-Z_]{1,48}")) return;
        if (fields == null || fields.length() > 400 || !fields.matches("[A-Za-z0-9_.= -]*")) return;
        try {
            JSONObject row = new JSONObject();
            row.put("wallMs", System.currentTimeMillis());
            row.put("elapsedMs", SystemClock.elapsedRealtime());
            row.put("uptimeMs", SystemClock.uptimeMillis());
            row.put("event", name);
            row.put("detail", fields);
            byte[] bytes = (row.toString() + "\n").getBytes(StandardCharsets.UTF_8);
            File current = new File(context.getFilesDir(), "phone-diagnostics.jsonl");
            File previous = new File(context.getFilesDir(), "phone-diagnostics.previous.jsonl");
            if (current.length() + bytes.length > MAX_BYTES) {
                if (previous.exists() && !previous.delete()) return;
                if (!current.renameTo(previous)) return;
            }
            try (FileOutputStream out = new FileOutputStream(current, true)) { out.write(bytes); }
        } catch (Exception ignored) { Log.w(TAG, "DIAGNOSTIC_WRITE_FAILED"); }
    }
}
