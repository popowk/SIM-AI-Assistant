package com.popowk.simai.companion;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Explicit ordered broadcast restricted to system/authorized ADB shell. */
public final class DiagnosticCommandReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !"com.popowk.simai.companion.CLEAR_DIAGNOSTICS".equals(intent.getAction())) return;
        boolean cleared = CallMonitorService.clearDiagnosticHistory(context);
        setResultCode(cleared ? 1 : 0);
        setResultData(cleared ? "SIMAI_DIAGNOSTICS_CLEARED" : "SIMAI_DIAGNOSTICS_CLEAR_FAILED");
    }
}
