package com.popowk.simai.companion;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.telephony.TelephonyManager;

/** Supplement the explicitly enabled foreground listener with Android's
 * protected PHONE_STATE broadcast. Never read the incoming number. */
public final class PhoneStateWakeReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (!TelephonyManager.ACTION_PHONE_STATE_CHANGED.equals(intent.getAction())) return;
        if (!context.getSharedPreferences("simai_initial_setup", Context.MODE_PRIVATE)
                .getBoolean("phone_state_monitor_desired", true)) return;
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) return;
        String state = intent.getStringExtra(TelephonyManager.EXTRA_STATE);
        int value;
        if (TelephonyManager.EXTRA_STATE_RINGING.equals(state)) value = TelephonyManager.CALL_STATE_RINGING;
        else if (TelephonyManager.EXTRA_STATE_OFFHOOK.equals(state)) value = TelephonyManager.CALL_STATE_OFFHOOK;
        else if (TelephonyManager.EXTRA_STATE_IDLE.equals(state)) value = TelephonyManager.CALL_STATE_IDLE;
        else return;
        if (CallMonitorService.running) {
            CallMonitorService.deliverSystemPhoneState(value);
            return;
        }
        // Only request a restart of the user's existing foreground service.
        // Android/OEM policy may deny background startup; never bypass it.
        try {
            Intent start = new Intent(context, CallMonitorService.class);
            start.putExtra("system_phone_state", value);
            start.putExtra("system_phone_state_elapsed", android.os.SystemClock.elapsedRealtime());
            context.startForegroundService(start);
            CallMonitorService.note("系统电话广播请求恢复前台监听");
        } catch (Exception denied) {
            CallMonitorService.note("系统电话广播恢复被系统拒绝：" + denied.getClass().getSimpleName());
        }
    }
}
