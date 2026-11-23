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
        persistSnapshot();
    }

    void start() throws Exception {
        if (active) return;
        listener = new ServerSocket(PORT, 12, InetAddress.getByName("127.0.0.1"));
        requests = new ThreadPoolExecutor(2, 2, 30L, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(8), job -> {
                    Thread thread = new Thread(job, "SIMAI-CallBridge-Request");
                    thread.setDaemon(true);
                    return thread;
                });
        active = true;
        persistSnapshot();
        heartbeat = Executors.newSingleThreadScheduledExecutor(job -> {
            Thread thread = new Thread(job, "SIMAI-Snapshot-Heartbeat");
            thread.setDaemon(true);
            return thread;
        });
        heartbeat.scheduleWithFixedDelay(() -> {
            if (active) {
                synchronized (PhoneEventBridge.this) { persistSnapshot(); }
            }
        }, 10, 10, TimeUnit.SECONDS);
        privateAnswerPoller = Executors.newSingleThreadScheduledExecutor(job -> {
            Thread thread = new Thread(job, "SIMAI-PrivateAnswer");
            thread.setDaemon(true);
            return thread;
        });
        privateAnswerPoller.scheduleWithFixedDelay(this::processPrivateAnswerRequest,
                0, 250, TimeUnit.MILLISECONDS);
        worker = new Thread(this::serve, "SIMAI-CallEventBridge");
        worker.setDaemon(true);
        worker.start();
        Log.i("SIMAICompanion", "Loopback call-state bridge listening (no phone identifiers)");
    }

    void stop() {
        active = false;
        if (heartbeat != null) heartbeat.shutdownNow();
        if (privateAnswerPoller != null) privateAnswerPoller.shutdownNow();
        synchronized (this) { persistSnapshot(); }
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

    /** One-shot answer path independent of Android's HTTP listener. */
    private void processPrivateAnswerRequest() {
        if (!active || !privateAnswerRequest.isFile()) return;
        String request;
        try (FileInputStream input = new FileInputStream(privateAnswerRequest)) {
            if (privateAnswerRequest.length() > 128 ||
                    System.currentTimeMillis() - privateAnswerRequest.lastModified() > 10000) {
                privateAnswerRequest.delete();
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
        if (!privateAnswerRequest.delete()) return;
        String[] parts = request.split("\\|", -1);
        if (parts.length != 2 || !parts[0].matches("[a-fA-F0-9-]{36}")) return;
        int ringSequence;
        try { ringSequence = Integer.parseInt(parts[1]); }
        catch (NumberFormatException invalid) { return; }
        String result = acceptGuardedPrivateAnswer(parts[0], ringSequence);
        String acknowledgement = parts[0] + "|" + parts[1] + "|" + result + "\n";
        File temp = new File(context.getFilesDir(), "bridge-answer-result.tmp");
        try (FileOutputStream output = new FileOutputStream(temp, false)) {
            output.write(acknowledgement.getBytes(StandardCharsets.US_ASCII));
            output.flush();
        } catch (Exception unavailable) { return; }
        if (!temp.renameTo(privateAnswerResult))
            Log.w("SIMAICompanion", "Private answer acknowledgement unavailable");
    }

    private synchronized String acceptGuardedPrivateAnswer(
            String expectedSession, int ringSequence) {
        if (!active || !session.equals(expectedSession) || ringSequence <= 0 ||
                sequence != ringSequence || !"RINGING".equals(lastState))
            return "RING_CHANGED";
        if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
                != PackageManager.PERMISSION_GRANTED) return "PERMISSION_REQUIRED";
        try {
            TelephonyManager phone = (TelephonyManager)
                    context.getSystemService(Context.TELEPHONY_SERVICE);
            TelecomManager telecom = (TelecomManager)
                    context.getSystemService(Context.TELECOM_SERVICE);
            if (phone == null || telecom == null ||
                    phone.getCallState() != TelephonyManager.CALL_STATE_RINGING)
                return "NOT_RINGING";
            telecom.acceptRingingCall();
            return "ANSWER_REQUESTED";
        } catch (SecurityException permission) {
            return "PERMISSION_REQUIRED";
        } catch (Exception unavailable) {
            return "ANSWER_UNAVAILABLE";
        }
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
            // Authorized call action; no phone numbers or audio are processed.
            // Check the actual device call state just before the action; a
            // stale RINGING event must not answer a different call later.
            if (contentLength > 0) {
                reply(client, 400, "{\"error\":\"body_not_allowed\"}");
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
                if ((!expectedSession.isEmpty() || expectedSequence > 0) &&
                        (!session.equals(expectedSession) ||
                         sequence != expectedSequence || !"RINGING".equals(lastState))) {
                    reply(client, 409, "{\"error\":\"ring_changed\"}");
                    return;
                }
                if (phone == null || telecom == null ||
                        phone.getCallState() != TelephonyManager.CALL_STATE_RINGING) {
                    reply(client, 409, "{\"error\":\"not_ringing\"}");
                    return;
                }
                // Android 13 still exposes this deprecated API to ordinary
                // apps with ANSWER_PHONE_CALLS. OEM may reject the request.
                telecom.acceptRingingCall();
                reply(client, 200, "{\"ok\":true,\"result\":\"answer_requested\"}");
            } catch (SecurityException permission) {
                reply(client, 403, "{\"error\":\"answer_permission_denied\"}");
            } catch (Exception unavailable) {
                reply(client, 503, "{\"error\":\"answer_unavailable\"}");
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
    private synchronized void persistSnapshot() {
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
