package com.popowk.simai.companion;

import android.content.Context;
import android.util.Log;
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

/**
 * Tiny read-only call-state endpoint, available only on Android loopback.
 * The Mac reaches it through an explicitly authorized USB adb forward.
 * A random per-install token remains in the app's private data directory.
 */
final class PhoneEventBridge {
    static final int PORT = 18764;
    private static final int MAX_EVENTS = 64;
    private final String session = UUID.randomUUID().toString();
    private final String token;
    private final List<CallEvent> events = new ArrayList<>();
    private volatile boolean active;
    private volatile String lastState = "UNKNOWN";
    private int sequence = 0;
    private ServerSocket listener;
    private Thread worker;

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
    }

    void start() throws Exception {
        if (active) return;
        listener = new ServerSocket(PORT, 4, InetAddress.getByName("127.0.0.1"));
        active = true;
        worker = new Thread(this::serve, "SIMAI-CallEventBridge");
        worker.setDaemon(true);
        worker.start();
        Log.i("SIMAICompanion", "Local USB diagnostic bridge listening (no phone identifiers)");
    }

    void stop() {
        active = false;
        try { if (listener != null) listener.close(); } catch (Exception ignored) {}
        if (worker != null) worker.interrupt();
    }

    private void serve() {
        while (active) {
            try (Socket client = listener.accept()) {
                client.setSoTimeout(2000);
                handle(client);
            } catch (Exception error) {
                if (active) Log.w("SIMAICompanion", "Local bridge request failed: "
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
        JSONObject body = new JSONObject();
        body.put("schema", 1);
        body.put("session", session);
        body.put("running", active);
        synchronized (this) {
            body.put("state", lastState);
            body.put("seq", sequence);
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
        }
        reply(client, 200, body.toString());
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
