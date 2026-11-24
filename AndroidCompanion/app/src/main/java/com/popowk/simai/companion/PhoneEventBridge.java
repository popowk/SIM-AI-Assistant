package com.popowk.simai.companion;

import android.content.Context;
import android.Manifest;
import android.content.pm.PackageManager;
import android.telecom.TelecomManager;
import android.telephony.TelephonyManager;
import android.util.Log;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;

/**
 * Tiny read-only call-state endpoint, available only on Android loopback.
 * The Mac reaches it through an explicitly authorized USB adb forward.
 * A random per-install token remains in the app's private data directory.
 */
final class PhoneEventBridge {
    static final int PORT = 18764;
    private static final int MAX_EVENTS = 64;
    private final String session = UUID.randomUUID().toString();
    private final AtomicFile snapshotFile;
    private final Context context;
    private ScheduledExecutorService heartbeat;
    private final String token;
    private final List<CallEvent> events = new ArrayList<>();
    private volatile boolean active;
    private volatile String lastState = "UNKNOWN";
    private int sequence = 0;
    private ServerSocket listener;
    private Thread worker;
    private ThreadPoolExecutor requests;
    private final File privateAnswerRequest;
    private final File privateAnswerResult;
    private ScheduledExecutorService privateAnswerPoller;
    private ScheduledExecutorService stateQueryWorker;
    private final Object snapshotWriteLock = new Object();
    private final java.util.concurrent.atomic.AtomicBoolean snapshotQueued = new java.util.concurrent.atomic.AtomicBoolean();
    private final NsdHelper nsdHelper = new NsdHelper();
    private volatile long lastRealPhoneStateAt = 0;
    private volatile String lastAnswerTransport = "NONE";
    // Anonymous health/status markers, never phone numbers or request tokens.
    private volatile long lastPrivateAnswerPollAt = 0;
    private volatile int lastPrivateAnswerSequence = 0;
    private volatile String lastPrivateAnswerResult = "NO_REQUEST";
    private volatile long lastTelephonyReconcileAt = 0;
    private volatile String lastRealPhoneState = "UNKNOWN";

    private static final class CallEvent {
        final int seq;
        final String state;
        final long at;
        CallEvent(int seq, String state, long at) {
            this.seq = seq; this.state = state; this.at = at;
        }
    }

    PhoneEventBridge(Context context) throws Exception {
        this.context = context.getApplicationContext();
        token = loadToken(context);
        snapshotFile = new AtomicFile(new File(context.getFilesDir(), "bridge-snapshot.json"));
        privateAnswerRequest = new File(context.getFilesDir(), "bridge-answer-request");
        privateAnswerResult = new File(context.getFilesDir(), "bridge-answer-result");
    }

    private static String loadToken(Context context) throws Exception {
        File file = new File(context.getFilesDir(), "bridge-token");
        if (file.isFile()) {
            byte[] data;
            try (FileInputStream stream = new FileInputStream(file)) {
                data = new byte[100];
                int length = stream.read(data);
                if (length == 64) {
                    String current = new String(data, 0, length, StandardCharsets.US_ASCII);
                    if (current.matches("[a-f0-9]{64}")) return current;
                }
            }
        }
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        StringBuilder hex = new StringBuilder(64);
        for (byte b : random) hex.append(String.format(Locale.US, "%02x", b & 0xff));
        try (FileOutputStream stream = new FileOutputStream(file, false)) {
            stream.write(hex.toString().getBytes(StandardCharsets.US_ASCII));
        }
        return hex.toString();
    }

    synchronized void recordState(String state) {
        if (!"IDLE".equals(state) && !"RINGING".equals(state) && !"OFFHOOK".equals(state))
            return;
        if (state.equals(lastState)) return;
        lastState = state;
        events.add(new CallEvent(++sequence, state, System.currentTimeMillis()));
        while (events.size() > MAX_EVENTS) events.remove(0);
        // Write snapshot immediately on state change so Mac poll reflects state within 1ms
        writeSnapshot();
    }

    void start() throws Exception {
        if (active) return;
        // Bind to all local interfaces (0.0.0.0) so Wi-Fi LAN direct and ADB forward loopback both work
        listener = new ServerSocket(PORT, 32);
        requests = new ThreadPoolExecutor(4, 8, 30L, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(32), job -> {
                    Thread thread = new Thread(job, "SIMAI-CallBridge-Request");
                    thread.setDaemon(true);
                    return thread;
                });
        active = true;
        heartbeat = Executors.newSingleThreadScheduledExecutor(job -> {
            Thread thread = new Thread(job, "SIMAI-Snapshot-Heartbeat");
            thread.setDaemon(true);
            return thread;
        });
        writeSnapshot();
        heartbeat.scheduleWithFixedDelay(() -> {
            if (active) writeSnapshot();
        }, 1, 1, TimeUnit.SECONDS);
        // Register mDNS / Bonjour for zero-config Mac discovery over Wi-Fi
        nsdHelper.register(context, PORT);
        privateAnswerPoller = Executors.newSingleThreadScheduledExecutor(job -> {
            Thread thread = new Thread(job, "SIMAI-PrivateAnswer");
            thread.setDaemon(true);
            return thread;
        });
        privateAnswerPoller.scheduleWithFixedDelay(() -> {
            try { processPrivateAnswerRequest(); }
            catch (Exception failure) {
                Log.w("SIMAICompanion", "Answer request poll: " +
                      failure.getClass().getSimpleName());
            }
        }, 0, 250, TimeUnit.MILLISECONDS);
        stateQueryWorker = Executors.newSingleThreadScheduledExecutor(job -> {
            Thread thread = new Thread(job, "SIMAI-Telephony-Query");
            thread.setDaemon(true);
            return thread;
        });
        stateQueryWorker.scheduleWithFixedDelay(this::reconcileRealCallState,
                0, 1, TimeUnit.SECONDS);
        worker = new Thread(this::serve, "SIMAI-CallEventBridge");
        worker.setDaemon(true);
        worker.start();
        Log.i("SIMAICompanion", "Loopback call-state bridge listening (no phone identifiers)");
    }

    void stop() {
        active = false;
        nsdHelper.unregister();
        if (stateQueryWorker != null) stateQueryWorker.shutdownNow();
        if (privateAnswerPoller != null) privateAnswerPoller.shutdownNow();
        if (heartbeat != null) heartbeat.shutdownNow();
        writeSnapshot();
        try { if (listener != null) listener.close(); } catch (Exception ignored) {}
        if (worker != null) worker.interrupt();
        if (requests != null) requests.shutdownNow();
    }

    private void serve() {
        while (active) {
            try {
                final Socket client = listener.accept();
                if (!active) { client.close(); break; }
                try {
                    requests.execute(() -> {
                        try (Socket connected = client) {
                            connected.setTcpNoDelay(true);
                            connected.setSoTimeout(1500);
                            handle(connected);
                        } catch (Exception error) {
                            if (active) Log.w("SIMAICompanion", "Local bridge request: "
                                    + error.getClass().getSimpleName());
                        }
                    });
                } catch (RejectedExecutionException busy) {
                    // Never let stalled requests block the accept loop.
                    client.close();
                }
            } catch (Exception error) {
                if (active) Log.w("SIMAICompanion", "Bridge accept failed: "
                        + error.getClass().getSimpleName());
            }
        }
    }

    /**
     * OEM telephony callbacks can be delayed while the screen is locked.
     * Poll the actual TelephonyManager state periodically from this already
     * foreground-running service, rather than leaving the Mac at RINGING
     * until a delayed OFFHOOK+IDLE batch arrives. No caller ID is accessed.
     */
    private void reconcileRealCallState() {
        if (!active) return;
        long now = System.currentTimeMillis();
        if (now - lastTelephonyReconcileAt < 900) return;
        lastTelephonyReconcileAt = now;
        try {
            if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                    != PackageManager.PERMISSION_GRANTED) return;
            TelephonyManager phone = (TelephonyManager)
                    context.getSystemService(Context.TELEPHONY_SERVICE);
            if (phone == null) return;
            int observed = phone.getCallState();
            String current = observed == TelephonyManager.CALL_STATE_RINGING
                    ? "RINGING" : observed == TelephonyManager.CALL_STATE_OFFHOOK
                    ? "OFFHOOK" : observed == TelephonyManager.CALL_STATE_IDLE
                    ? "IDLE" : "UNKNOWN";
            if ("UNKNOWN".equals(current)) return;
            // The Android documentation explicitly allows this query to
            // differ from the subscription callback. Never overwrite live
            // cellular events with this potentially stale aggregate value.
            lastRealPhoneState = current;
            lastRealPhoneStateAt = System.currentTimeMillis();
        } catch (SecurityException ignored) {
            // Permission may have been revoked by Android system settings.
        } catch (Exception ignored) {
            // Do not stop the foreground monitor if OEM API is unavailable.
        }
    }

    /** One-shot answer path independent of Android's HTTP listener. */
    private void processPrivateAnswerRequest() {
        lastPrivateAnswerPollAt = System.currentTimeMillis();
        if (!active || !privateAnswerRequest.isFile()) return;
        String request;
        try (FileInputStream input = new FileInputStream(privateAnswerRequest)) {
            if (privateAnswerRequest.length() > 128 ||
                    System.currentTimeMillis() - privateAnswerRequest.lastModified() > 10000) {
                privateAnswerRequest.delete();
                lastPrivateAnswerResult = "REQUEST_STALE";
                persistSnapshot();
                return;
            }
            byte[] bytes = new byte[128];
            int count = input.read(bytes);
            if (count <= 0 || count == bytes.length) {
                privateAnswerRequest.delete();
                return;
            }
            request = new String(bytes, 0, count, StandardCharsets.US_ASCII).trim();
        } catch (Exception unavailable) { return; }
        if (!privateAnswerRequest.delete()) {
            lastPrivateAnswerResult = "REQUEST_DELETE_FAILED";
            persistSnapshot();
            return;
        }
        String[] parts = request.split("\\|", -1);
        if (parts.length != 2 || !parts[0].matches("[a-fA-F0-9-]{36}")) {
            lastPrivateAnswerResult = "REQUEST_INVALID";
            persistSnapshot();
            return;
        }
        int ringSequence;
        try { ringSequence = Integer.parseInt(parts[1]); }
        catch (NumberFormatException invalid) {
            lastPrivateAnswerResult = "REQUEST_INVALID";
            persistSnapshot();
            return;
        }
        String result = acceptGuardedAnswer(parts[0], ringSequence, "FILE");
        // Persist an independent acknowledgement in the established ADB_FILE
        // snapshot even if the separate result file cannot be read on vivo.
        persistSnapshot();
        String acknowledgement = parts[0] + "|" + parts[1] + "|" + result + "\n";
        File temp = new File(context.getFilesDir(), "bridge-answer-result.tmp");
        try (FileOutputStream output = new FileOutputStream(temp, false)) {
            output.write(acknowledgement.getBytes(StandardCharsets.US_ASCII));
            output.flush();
        } catch (Exception unavailable) { return; }
        if (!temp.renameTo(privateAnswerResult))
            Log.w("SIMAICompanion", "Private answer acknowledgement unavailable");
    }

    /** Shared guarded entry point for HTTP, shell broadcast and private file. */
    String acceptAndRecordGuardedShellRequest(String expectedSession, int expectedSequence) {
        return acceptGuardedAnswer(expectedSession, expectedSequence, "BROADCAST");
    }

    private String acceptGuardedAnswer(String expectedSession, int ringSequence, String transport) {
        // Do not hold the state lock across Telecom Binder calls, file fsync,
        // or sockets. A stalled vendor API must not block state publication.
        synchronized (this) {
            if (!active || expectedSession == null || !session.equals(expectedSession)
                    || ringSequence <= 0 || sequence != ringSequence
                    || !"RINGING".equals(lastState) || events.isEmpty())
                return "RING_CHANGED";
            long age = System.currentTimeMillis() - events.get(events.size() - 1).at;
            if (age < 0 || age > 35000) return "RING_EXPIRED";
            if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
                    != PackageManager.PERMISSION_GRANTED) return "PERMISSION_REQUIRED";
            if (lastPrivateAnswerSequence == ringSequence &&
                    ("ANSWER_REQUESTED".equals(lastPrivateAnswerResult)
                    || "ANSWER_IN_PROGRESS".equals(lastPrivateAnswerResult)))
                return lastPrivateAnswerResult;
            lastPrivateAnswerSequence = ringSequence;
            lastPrivateAnswerResult = "ANSWER_IN_PROGRESS";
            lastAnswerTransport = transport;
            persistSnapshot();
        }
        String result;
        try {
            TelecomManager telecom = (TelecomManager)
                    context.getSystemService(Context.TELECOM_SERVICE);
            if (telecom == null) {
                result = "ANSWER_UNAVAILABLE";
            } else {
                // The current, permission-checked cellular RINGING callback
                // is the guard. acceptRingingCall itself only accepts an
                // actually ringing incoming call. Do not gate it on a second
                // deprecated aggregate getCallState() result.
                synchronized (this) {
                    if (!active || sequence != ringSequence || !"RINGING".equals(lastState)) {
                        lastPrivateAnswerResult = "RING_CHANGED";
                        persistSnapshot();
                        return "RING_CHANGED";
                    }
                }
                Log.i("SIMAICompanion", "Answer invoked via " + transport);
                if (ShizukuTelephonyBridge.isReady()) {
                    String shizukuRes = ShizukuTelephonyBridge.answerCall(context);
                    if ("ANSWER_REQUESTED".equals(shizukuRes)) {
                        result = "ANSWER_REQUESTED";
                    } else {
                        telecom.acceptRingingCall();
                        result = "ANSWER_REQUESTED";
                    }
                } else {
                    telecom.acceptRingingCall();
                    result = "ANSWER_REQUESTED";
                }
            }
        } catch (SecurityException permission) {
            result = "PERMISSION_REQUIRED";
        } catch (Exception unavailable) {
            result = "ANSWER_UNAVAILABLE";
        }
        synchronized (this) {
            if (lastPrivateAnswerSequence == ringSequence) {
                lastPrivateAnswerResult = result;
                persistSnapshot();
            }
        }
        Log.i("SIMAICompanion", "Answer result via " + transport + ": " + result);
        return result;
    }

    private void handle(Socket client) throws Exception {
        // Read HTTP headers byte-by-byte. BufferedReader may read beyond the
        // blank line and swallow POST body bytes before JSON parsing.
        InputStream in = client.getInputStream();
        String first = readHeaderLine(in, 256);
        if (first == null) return;
        String accessToken = "";
        String expectedSession = "";
        int expectedSequence = -1;
        int contentLength = -1;
        String contentType = "";
        boolean headersEnded = false;
        for (int i = 0; i < 32; i++) {
            String line = readHeaderLine(in, 512);
            if (line == null) return;
            if (line.isEmpty()) {
                headersEnded = true;
                break;
            }
            String lower = line.toLowerCase(Locale.US);
            if (lower.startsWith("x-simai-token:"))
                accessToken = line.substring("x-simai-token:".length()).trim();
            else if (lower.startsWith("x-simai-expected-session:"))
                expectedSession = line.substring("x-simai-expected-session:".length()).trim();
            else if (lower.startsWith("x-simai-expected-sequence:")) {
                try { expectedSequence = Integer.parseInt(
                        line.substring("x-simai-expected-sequence:".length()).trim()); }
                catch (NumberFormatException invalid) { return; }
            }
            else if (lower.startsWith("content-length:")) {
                try { contentLength = Integer.parseInt(line.substring(15).trim()); }
                catch (NumberFormatException invalid) { return; }
            } else if (lower.startsWith("content-type:")) {
                contentType = line.substring(13).trim().toLowerCase(Locale.US);
            }
        }
        if (!headersEnded) return;
        if (!accessToken.equals(token)) {
            reply(client, 403, "{\"error\":\"forbidden\"}");
            return;
        }

        if (first.startsWith("POST /call/answer HTTP/1.")) {
            if (contentLength > 0 || expectedSession.isEmpty() || expectedSequence <= 0) {
                reply(client, 400, "{\"error\":\"missing_call_guard\"}");
                return;
            }
            String result = acceptGuardedAnswer(expectedSession, expectedSequence, "HTTP");
            if ("ANSWER_REQUESTED".equals(result)) {
                reply(client, 200, "{\"ok\":true,\"result\":\"answer_requested\"}");
            } else {
                int status = "PERMISSION_REQUIRED".equals(result) ? 403
                    : "RING_CHANGED".equals(result) || "RING_EXPIRED".equals(result) ? 409
                    : "ANSWER_IN_PROGRESS".equals(result) ? 202 : 503;
                reply(client, status, "{\"error\":\"" + result + "\"}");
            }
            return;
        }

        if (first.startsWith("POST /call/hangup HTTP/1.")) {
            // Only a previously accepted, tracked call can be terminated.
            // The Mac must supply the current Android bridge session and
            // exact OFFHOOK sequence from its authenticated status snapshot.
            // This prevents a delayed Voice-ended request from hanging up
            // a newer/unrelated call after a bridge or phone-state change.
            if (contentLength > 0 || expectedSequence <= 0 ||
                    expectedSession.isEmpty()) {
                reply(client, 400, "{\"error\":\"missing_call_guard\"}");
                return;
            }
            if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
                    != PackageManager.PERMISSION_GRANTED) {
                reply(client, 403, "{\"error\":\"answer_permission_required\"}");
                return;
            }
            try {
                TelephonyManager phone = (TelephonyManager)
                        context.getSystemService(Context.TELEPHONY_SERVICE);
                TelecomManager telecom = (TelecomManager)
                        context.getSystemService(Context.TELECOM_SERVICE);
                synchronized (this) {
                    if (!active || !session.equals(expectedSession) ||
                            sequence != expectedSequence || !"OFFHOOK".equals(lastState) ||
                            phone == null || telecom == null ||
                            phone.getCallState() != TelephonyManager.CALL_STATE_OFFHOOK) {
                        reply(client, 409, "{\"error\":\"call_changed_or_not_active\"}");
                        return;
                    }
                    // Prefer privileged Shizuku hangup if available
                    if (ShizukuTelephonyBridge.isReady()) {
                        String shizukuRes = ShizukuTelephonyBridge.endCall(context);
                        if ("HANGUP_SUCCESS".equals(shizukuRes)) {
                            reply(client, 200, "{\"ok\":true,\"result\":\"hangup_requested\"}");
                            return;
                        }
                    }
                    // Android 13 exposes this permission-gated legacy API.
                    // OEM restrictions and emergency call protection still apply.
                    @SuppressWarnings("deprecation")
                    boolean requested = telecom.endCall();
                    if (requested) {
                        reply(client, 200, "{\"ok\":true,\"result\":\"hangup_requested\"}");
                    } else {
                        reply(client, 503, "{\"error\":\"hangup_unavailable\"}");
                    }
                }
            } catch (SecurityException permission) {
                reply(client, 403, "{\"error\":\"hangup_permission_denied\"}");
            } catch (Exception unavailable) {
                reply(client, 503, "{\"error\":\"hangup_unavailable\"}");
            }
            return;
        }

        if (first.startsWith("POST /sms/config HTTP/1.")) {
            if (contentLength < 2 || contentLength > 4096 ||
                    !contentType.startsWith("application/json")) {
                reply(client, 400, "{\"error\":\"invalid_request\"}");
                return;
            }
            byte[] body = new byte[contentLength];
            int received = 0;
            while (received < body.length) {
                int n = in.read(body, received, body.length - received);
                if (n <= 0) return;
                received += n;
            }
            try {
                JSONObject settings = new JSONObject(new String(body, StandardCharsets.UTF_8));
                String webhook = settings.optString("webhook", "");
                String signingSecret = settings.optString("secret", "");
                if (!settings.has("enabled") || !(settings.opt("enabled") instanceof Boolean)
                        || signingSecret.getBytes(StandardCharsets.UTF_8).length > 256
                        || !SmsWebhookForwarder.validWebhook(webhook)) {
                    reply(client, 422, "{\"error\":\"invalid_settings\"}");
                    return;
                }
                // Never echo or log credentials or SMS data. The phone retains
                // its own private config for independent sending after unplug.
                if (!SmsWebhookForwarder.configure(context, webhook, signingSecret, true)) {
                    reply(client, 500, "{\"error\":\"save_failed\"}");
                    return;
                }
                SmsWebhookForwarder.setEnabled(context, settings.getBoolean("enabled"));
                boolean granted = context.checkSelfPermission(
                        android.Manifest.permission.RECEIVE_SMS)
                        == android.content.pm.PackageManager.PERMISSION_GRANTED;
                reply(client, 200, "{\"ok\":true,\"configured\":true,\"enabled\":" +
                        SmsWebhookForwarder.isEnabled(context) +
                        ",\"smsPermissionGranted\":" + granted + "}");
            } catch (org.json.JSONException invalid) {
                reply(client, 422, "{\"error\":\"invalid_json\"}");
            }
            return;
        }

        if (first.startsWith("GET /sms/status HTTP/1.")) {
            boolean granted = context.checkSelfPermission(
                    android.Manifest.permission.RECEIVE_SMS)
                    == android.content.pm.PackageManager.PERMISSION_GRANTED;
            reply(client, 200, "{\"ok\":true,\"configured\":" +
                    SmsWebhookForwarder.hasConfiguration(context) +
                    ",\"enabled\":" + SmsWebhookForwarder.isEnabled(context) +
                    ",\"smsPermissionGranted\":" + granted + "}");
            return;
        }

        if (first.startsWith("GET /ping HTTP/1.")) {
            reply(client, 200, "{\"ok\":true,\"status\":\"pong\"}");
            return;
        }

        if (!first.startsWith("GET /events?since=")) {
            reply(client, 404, "{\"error\":\"not_found\"}");
            return;
        }
        int start = first.indexOf("since=") + 6;
        int end = first.indexOf(' ', start);
        if (end < 0) return;
        long since;
        try { since = Long.parseLong(first.substring(start, end)); }
        catch (NumberFormatException ignored) { since = 0; }
        if (since < 0) since = 0;
        JSONObject body;
        synchronized (this) { body = snapshot(since); }
        reply(client, 200, body.toString());
    }

    private static String readHeaderLine(InputStream in, int max) throws Exception {
        StringBuilder line = new StringBuilder();
        while (line.length() < max) {
            int next = in.read();
            if (next < 0) return null;
            if (next == '\n') {
                if (line.length() > 0 && line.charAt(line.length() - 1) == '\r')
                    line.setLength(line.length() - 1);
                return line.toString();
            }
            if (next < 32 && next != '\r' && next != '\t') return null;
            if (next > 126) return null;
            line.append((char) next);
        }
        return null;
    }

    private synchronized JSONObject snapshot(long since) throws Exception {
        JSONObject body = new JSONObject();
        body.put("schema", 1);
        body.put("session", session);
        body.put("running", active);
        body.put("state", lastState);
        body.put("seq", sequence);
        body.put("updatedAt", System.currentTimeMillis());
        body.put("shizukuReady", ShizukuTelephonyBridge.isReady());
        body.put("wifiListening", true);
        body.put("answerPermissionGranted",
                context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
                    == PackageManager.PERMISSION_GRANTED);
        body.put("adbBroadcastAnswerAvailable", true);
        body.put("realPhoneState", lastRealPhoneState);
        body.put("realPhoneStateAt", lastRealPhoneStateAt);
        body.put("lastAnswerTransport", lastAnswerTransport);
        body.put("orderedAnswerReplyAvailable", true);
        body.put("privateAnswerPollerActive",
                active && lastPrivateAnswerPollAt > 0 &&
                System.currentTimeMillis() - lastPrivateAnswerPollAt < 5000);
        body.put("privateAnswerSequence", lastPrivateAnswerSequence);
        body.put("privateAnswerResult", lastPrivateAnswerResult);
        JSONArray rows = new JSONArray();
        for (CallEvent event : events) {
            if (event.seq <= since) continue;
            JSONObject row = new JSONObject();
            row.put("seq", event.seq);
            row.put("state", event.state);
            row.put("at", event.at);
            rows.put(row);
        }
        body.put("events", rows);
        return body;
    }

    /// Atomic private snapshot is read only via previously authorized ADB
    /// "run-as" when the HTTP status tunnel stalls during screen-off.
    /// No numbers, contacts, speech or raw audio are persisted.
    private void persistSnapshot() {
        ScheduledExecutorService writer = heartbeat;
        if (writer == null || writer.isShutdown() || !snapshotQueued.compareAndSet(false, true)) return;
        try {
            writer.execute(() -> {
                snapshotQueued.set(false);
                writeSnapshot();
            });
        } catch (RejectedExecutionException ignored) { snapshotQueued.set(false); }
    }

    private void writeSnapshot() {
        synchronized (snapshotWriteLock) {
            FileOutputStream out = null;
            try {
                byte[] bytes = snapshot(0).toString().getBytes(StandardCharsets.UTF_8);
                out = snapshotFile.startWrite();
                out.write(bytes);
                snapshotFile.finishWrite(out);
            } catch (Exception error) {
                if (out != null) snapshotFile.failWrite(out);
                Log.w("SIMAICompanion", "Anonymous state snapshot failed: "
                        + error.getClass().getSimpleName());
            }
        }
    }

    private static void reply(Socket client, int status, String body) throws Exception {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String headers = "HTTP/1.1 " + status + (status == 200 ? " OK" : " Error")
                + "\r\nContent-Type: application/json; charset=utf-8"
                + "\r\nCache-Control: no-store\r\nConnection: close"
                + "\r\nContent-Length: " + bytes.length + "\r\n\r\n";
        OutputStream out = client.getOutputStream();
        out.write(headers.getBytes(StandardCharsets.US_ASCII));
        out.write(bytes);
        out.flush();
    }
}
