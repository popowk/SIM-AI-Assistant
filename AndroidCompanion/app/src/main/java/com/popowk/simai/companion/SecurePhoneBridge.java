package com.popowk.simai.companion;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.ParcelFileDescriptor;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.system.OsConstants;
import java.io.*;
import java.net.Socket;
import java.security.*;
import java.security.cert.Certificate;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.*;

/** Dedicated opt-in TLS listener. A physical-phone pairing code pins the
 * non-exportable certificate and carries a random bearer secret. The old USB
 * HTTP service and shell helper remain on loopback only. */
final class SecurePhoneBridge {
    static final int PORT = 18766;
    private static final String PREFS = "simai_secure_wifi";
    private static final String ALIAS = "simai_wifi_server_v1";
    interface Handler { void handle(Socket socket) throws Exception; }
    private final Context context;
    private final Handler handler;
    private final ShizukuAudioClient audio;
    private volatile SSLServerSocket server;
    private volatile ThreadPoolExecutor pool;
    private final Set<Socket> clients = ConcurrentHashMap.newKeySet();

    SecurePhoneBridge(Context context, Handler handler) {
        this.context = context.getApplicationContext();
        this.handler = handler;
        this.audio = new ShizukuAudioClient(context);
    }
    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
    private static String hex(byte[] bytes) {
        StringBuilder b = new StringBuilder(bytes.length * 2);
        for (byte v : bytes) b.append(String.format(Locale.US, "%02x", v & 255));
        return b.toString();
    }
    private static synchronized KeyStore keyStore() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyPairGenerator g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            g.initialize(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                .setKeySize(2048)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                .setCertificateSubject(new javax.security.auth.x500.X500Principal("CN=SIM AI Companion"))
                .setCertificateNotBefore(new Date(System.currentTimeMillis() - 86400000L))
                .setCertificateNotAfter(new Date(System.currentTimeMillis() + 315360000000L))
                .build());
            g.generateKeyPair();
            ks.load(null);
        }
        return ks;
    }
    static synchronized String enableAndCode(Context context) throws Exception {
        Certificate cert = keyStore().getCertificate(ALIAS);
        String pin = hex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
        SharedPreferences p = prefs(context);
        String token = p.getString("token", "");
        if (token == null || !token.matches("[a-f0-9]{64}")) {
            byte[] random = new byte[32]; new SecureRandom().nextBytes(random); token = hex(random);
        }
        if (!p.edit().putString("token", token).putBoolean("enabled", true).commit())
            throw new IOException("PREFERENCE_WRITE");
        return pin + ":" + token;
    }
    static void disable(Context context) {
        prefs(context).edit().putBoolean("enabled", false).remove("token").apply();
    }
    private boolean enabled() { return prefs(context).getBoolean("enabled", false); }
    boolean authorize(String presented) {
        String token = prefs(context).getString("token", "");
        return enabled() && token != null && token.matches("[a-f0-9]{64}") &&
                presented != null && MessageDigest.isEqual(token.getBytes(java.nio.charset.StandardCharsets.US_ASCII),
                presented.getBytes(java.nio.charset.StandardCharsets.US_ASCII));
    }
    boolean audioReady() { return enabled() && server != null && audio.ready(); }
    boolean listening() { return server != null && enabled(); }

    synchronized void reconcile() {
        if (!enabled()) { stop(); return; }
        audio.reconcile(true);
        if (server != null) return;
        try {
            KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(keyStore(), null);
            SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(kmf.getKeyManagers(), null, new SecureRandom());
            SSLServerSocket listener = (SSLServerSocket) tls.getServerSocketFactory().createServerSocket(PORT, 8);
            listener.setEnabledProtocols(new String[]{"TLSv1.2", "TLSv1.3"});
            listener.setNeedClientAuth(false);
            ThreadPoolExecutor executor = new ThreadPoolExecutor(2, 6, 30, TimeUnit.SECONDS,
                    new ArrayBlockingQueue<>(8), job -> {
                Thread t = new Thread(job, "SIMAI-TLS-Client"); t.setDaemon(true); return t;
            });
            pool = executor; server = listener;
            Thread accept = new Thread(() -> {
                while (server == listener && enabled()) {
                    try {
                        SSLSocket socket = (SSLSocket) listener.accept();
                        clients.add(socket);
                        try {
                            executor.execute(() -> {
                                try (SSLSocket client = socket) {
                                    client.setSoTimeout(5000); client.setTcpNoDelay(true);
                                    client.startHandshake();
                                    if (enabled() && server == listener) handler.handle(client);
                                } catch (Exception ignored) {} finally { clients.remove(socket); }
                            });
                        } catch (RejectedExecutionException rejected) {
                            clients.remove(socket); socket.close();
                        }
                    } catch (IOException closed) { break; }
                }
            }, "SIMAI-TLS-Listener");
            accept.setDaemon(true); accept.start();
        } catch (Exception failed) { stop(); }
    }

    synchronized void stop() {
        SSLServerSocket old = server; server = null;
        if (old != null) try { old.close(); } catch (IOException ignored) {}
        for (Socket socket : clients) try { socket.close(); } catch (IOException ignored) {}
        clients.clear();
        ThreadPoolExecutor executor = pool; pool = null;
        if (executor != null) executor.shutdownNow();
        audio.stop();
    }

    private static void closePair(ParcelFileDescriptor fd) {
        try { Os.shutdown(fd.getFileDescriptor(), OsConstants.SHUT_RDWR); } catch (Exception ignored) {}
        try { fd.close(); } catch (Exception ignored) {}
    }
    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[4096]; int n;
        while ((n = in.read(buffer)) >= 0) {
            if (n == 0) continue;
            out.write(buffer, 0, n); out.flush();
        }
    }
    void relayAudio(Socket socket, java.util.function.BooleanSupplier sameCall) throws Exception {
        if (!audioReady() || !sameCall.getAsBoolean()) { socket.getOutputStream().write("ERR SHIZUKU_NOT_READY\n".getBytes(java.nio.charset.StandardCharsets.US_ASCII)); return; }
        ParcelFileDescriptor[] pair = ParcelFileDescriptor.createSocketPair();
        ParcelFileDescriptor app = pair[0], shell = pair[1];
        boolean started;
        try { started = audio.start(shell); } finally { try { shell.close(); } catch (Exception ignored) {} }
        if (!started) {
            closePair(app);
            socket.getOutputStream().write("ERR SHIZUKU_AUDIO_BUSY\n".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
            return;
        }
        socket.setSoTimeout(6000);
        java.util.concurrent.atomic.AtomicBoolean finished = new java.util.concurrent.atomic.AtomicBoolean(false);
        Runnable finish = () -> {
            if (!finished.compareAndSet(false, true)) return;
            closePair(app);
            try { socket.close(); } catch (IOException ignored) {}
        };
        Thread watchdog = new Thread(() -> {
            long deadline = android.os.SystemClock.elapsedRealtime() + 185000;
            while (!finished.get()) {
                if (!enabled() || !audio.ready() || !sameCall.getAsBoolean() ||
                        android.os.SystemClock.elapsedRealtime() >= deadline) { finish.run(); break; }
                try { Thread.sleep(250); } catch (InterruptedException ignored) { break; }
            }
        }, "SIMAI-TLS-CallGuard");
        watchdog.setDaemon(true); watchdog.start();
        Thread uplink = new Thread(() -> {
            try { copy(socket.getInputStream(), new FileOutputStream(app.getFileDescriptor())); }
            catch (Exception ignored) {} finally { finish.run(); }
        }, "SIMAI-TLS-Uplink");
        uplink.setDaemon(true); uplink.start();
        try { copy(new FileInputStream(app.getFileDescriptor()), socket.getOutputStream()); }
        finally {
            finish.run(); watchdog.interrupt();
            try { uplink.join(1000); } catch (InterruptedException ignored) {}
        }
    }
}
