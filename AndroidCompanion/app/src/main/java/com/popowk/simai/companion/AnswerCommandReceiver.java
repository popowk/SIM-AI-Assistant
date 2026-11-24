package com.popowk.simai.companion;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Guarded secondary answer transport for the user's authorized ADB shell.
 * The manifest requires android.permission.DUMP (system/shell permission)
 * and the already-running call monitor verifies the exact ring and Android
 * ANSWER_PHONE_CALLS permission before attempting any action.
 *
 * The broadcast never contains phone numbers, audio or bearer credentials.
 */
public final class AnswerCommandReceiver extends BroadcastReceiver {
    static final String ACTION = "com.popowk.simai.companion.REQUEST_GUARDED_ANSWER";

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION.equals(intent.getAction())) return;
        String expectedSession = intent.getStringExtra("session");
        int expectedSequence = intent.getIntExtra("sequence", -1);
        if (expectedSession == null || expectedSequence <= 0 ||
                !expectedSession.matches("[a-fA-F0-9-]{36}")) return;
        // Return the explicit app result directly to the ordered ADB
        // broadcast rather than relying on a potentially stale state file.
        final PendingResult pending = goAsync();
        Thread worker = new Thread(() -> {
            try {
                String result = CallMonitorService.requestGuardedAnswerFromADB(
                        expectedSession, expectedSequence);
                pending.setResultCode("ANSWER_REQUESTED".equals(result) ? 1 : 0);
                pending.setResultData("SIMAI_" + result);
            } catch (Exception failed) {
                pending.setResultCode(0);
                pending.setResultData("SIMAI_ANSWER_UNAVAILABLE");
            } finally {
                pending.finish();
            }
        }, "SIMAI-GuardedAnswer");
        worker.setDaemon(true);
        worker.start();
    }
}
