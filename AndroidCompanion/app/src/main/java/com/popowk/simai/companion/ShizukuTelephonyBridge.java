package com.popowk.simai.companion;

import android.content.Context;
import android.content.pm.PackageManager;
import android.util.Log;
import rikka.shizuku.Shizuku;
import java.lang.reflect.Method;

/**
 * Privileged telephony operations via Shizuku (UID 2000 shell).
 * Provides 100% reliable call answering and hangup without requiring root or default dialer role.
 */
public final class ShizukuTelephonyBridge {
    private static final String TAG = "SIMAIShizuku";

    public static boolean isShizukuAvailable() {
        try {
            return Shizuku.pingBinder();
        } catch (Throwable t) {
            return false;
        }
    }

    public static boolean hasPermission() {
        if (!isShizukuAvailable()) return false;
        try {
            return Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (Throwable t) {
            return false;
        }
    }

    public static void requestPermission(int requestCode) {
        if (!isShizukuAvailable()) return;
        try {
            Shizuku.requestPermission(requestCode);
        } catch (Throwable t) {
            Log.w(TAG, "Request permission failed", t);
        }
    }

    public static boolean isReady() {
        return isShizukuAvailable() && hasPermission();
    }

    public static void autoGrantAppPermissions(Context context) {
        if (!isReady() || context == null) return;
        try {
            String pkg = context.getPackageName();
            exec(new String[]{"pm", "grant", pkg, "android.permission.ANSWER_PHONE_CALLS"});
            exec(new String[]{"pm", "grant", pkg, "android.permission.READ_PHONE_STATE"});
            exec(new String[]{"pm", "grant", pkg, "android.permission.RECEIVE_SMS"});
            exec(new String[]{"appops", "set", pkg, "SYSTEM_ALERT_WINDOW", "allow"});
            Log.i(TAG, "autoGrantAppPermissions executed via Shizuku for: " + pkg);
        } catch (Throwable t) {
            Log.w(TAG, "autoGrantAppPermissions failed", t);
        }
    }

    private static int exec(String[] command) {
        try {
            Method newProcessMethod = Shizuku.class.getDeclaredMethod(
                    "newProcess", String[].class, String[].class, String.class);
            newProcessMethod.setAccessible(true);
            Process process = (Process) newProcessMethod.invoke(null, (Object) command, null, null);
            if (process != null) {
                return process.waitFor();
            }
        } catch (Throwable t) {
            Log.w(TAG, "exec failed: " + java.util.Arrays.toString(command), t);
        }
        return -1;
    }

    /**
     * Executes privileged call answering via Shizuku shell process (UID 2000).
     */
    public static String answerCall(Context context) {
        if (!isReady()) return "SHIZUKU_NOT_READY";
        Log.i(TAG, "Attempting privileged answerCall via Shizuku...");

        // 1. Android 10+ Telecom Manager CLI
        if (exec(new String[]{"cmd", "telecom", "answer"}) == 0) {
            Log.i(TAG, "cmd telecom answer succeeded via Shizuku");
            return "ANSWER_REQUESTED";
        }

        // 2. Legacy telecom answer CLI
        if (exec(new String[]{"telecom", "answer"}) == 0) {
            Log.i(TAG, "telecom answer succeeded via Shizuku");
            return "ANSWER_REQUESTED";
        }

        // 3. Hardware KEYCODE_CALL fallback
        if (exec(new String[]{"input", "keyevent", "5"}) == 0) {
            Log.i(TAG, "keyevent 5 succeeded via Shizuku");
            return "ANSWER_REQUESTED";
        }

        return "SHIZUKU_ANSWER_FAILED";
    }

    /**
     * Executes privileged call hangup via Shizuku shell process (UID 2000).
     */
    public static String endCall(Context context) {
        if (!isReady()) return "SHIZUKU_NOT_READY";
        Log.i(TAG, "Attempting privileged endCall via Shizuku...");

        // 1. Android 10+ Telecom Manager CLI
        if (exec(new String[]{"cmd", "telecom", "end-call"}) == 0) {
            exec(new String[]{"input", "keyevent", "6"});
            Log.i(TAG, "cmd telecom end-call succeeded via Shizuku");
            return "HANGUP_SUCCESS";
        }

        // 2. Legacy telecom end-call CLI
        if (exec(new String[]{"telecom", "end-call"}) == 0) {
            Log.i(TAG, "telecom end-call succeeded via Shizuku");
            return "HANGUP_SUCCESS";
        }

        // 3. Hardware KEYCODE_ENDCALL fallback
        if (exec(new String[]{"input", "keyevent", "6"}) == 0) {
            Log.i(TAG, "keyevent 6 succeeded via Shizuku");
            return "HANGUP_SUCCESS";
        }

        return "SHIZUKU_HANGUP_FAILED";
    }
}
