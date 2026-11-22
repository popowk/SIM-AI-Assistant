package com.popowk.simai.companion;

import android.content.Context;
import android.util.Log;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
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
    private ScheduledExecutorService heartbeat;
    private final String token;
    private final List<CallEvent> events = new ArrayList<>();
    private volatile boolean active;
    private volatile String lastState = "UNKNOWN";
    private int sequence = 0;
    private ServerSocket listener;
    private Thread worker;
    private ThreadPoolExecutor requests;

    private static final class CallEvent {
        final int seq;
        final String state;
        final long at;
        CallEvent(int seq, String state, long at) {
            this.seq = seq; this.state = state; this.at = at;
        }
    }

    PhoneEventBridge(Context context) throws Exception {
        token = loadToken(context);
        snapshotFile = new AtomicFile(new File(context.getFilesDir(), "bridge-snapshot.json"));
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
        }, 15, 15, TimeUnit.SECONDS);
        worker = new Thread(this::serve, "SIMAI-CallEventBridge");
        worker.setDaemon(true);
        worker.start();
        Log.i("SIMAICompanion", "Loopback call-state bridge listening (no phone identifiers)");
    }

    void stop() {
        active = false;
        if (heartbeat != null) heartbeat.shutdownNow();
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

    private void handle(Socket client) throws Exception {
        BufferedReader reader = new BufferedReader(
                new InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII));
        String first = reader.readLine();
        if (first == null || first.length() > 256) return;
        String accessToken = "";
        for (int i = 0; i < 32; i++) {
            String line = reader.readLine();
            if (line == null || line.length() == 0) break;
            if (line.length() > 512) return;
            if (line.toLowerCase(Locale.US).startsWith("x-simai-token:"))
                accessToken = line.substring("x-simai-token:".length()).trim();
        }
        if (!accessToken.equals(token)) {
            reply(client, 403, "{\"error\":\"forbidden\"}");
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
