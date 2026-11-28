package dev.popowk.simai.probe;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.SystemClock;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Explicit opt-in, disposable 16 kHz mono PCM16 full-duplex cellular audio bridge.
 * Only binds 127.0.0.1, reached through user's already-authorized ADB forwarding.
 * Phone numbers, caller details, audio samples and session secret are NEVER logged.
 * Duration is hard-capped to three minutes; no automatic call answering.
 */
public final class AudioStreamServer {
    static final int PORT = 18765;
    private static final int RATE = 16000;
    private static final int FRAME_BYTES = 640; // 20 ms * mono 16 bit
    private static final long MAX_DURATION_MS = 180000;
    private static final int MODE_SCREENING = 4;
    private static final int MODE_REDIRECT = 5;

    private AudioStreamServer() {}

    static void serve(String secret) throws Exception {
        if (secret == null || !secret.matches("[a-f0-9]{64}"))
            throw new IllegalArgumentException("SESSION_KEY_INVALID");
        try (ServerSocket server = new ServerSocket(PORT, 1,
                InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(15000);
            try (Socket client = server.accept()) {
                client.setTcpNoDelay(true);
                client.setSoTimeout(5000);
                InputStream input = client.getInputStream();
                OutputStream output = client.getOutputStream();
                String request = readHeader(input);
                if (!("SIMAI_AUDIO_1 " + secret).equals(request)) {
                    output.write("ERR AUTH\n".getBytes(StandardCharsets.US_ASCII));
                    return;
                }
                serveConnected(input, output, () -> {
                    try { client.close(); } catch (Exception ignored) {}
                });
            }
        }
    }

    /** Non-recording idle preflight in the actual shell process. */
    public static boolean shellAudioAvailable() {
        try {
            return ProbeRuntime.context().getSystemService(AudioManager.class) != null &&
                    AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT) > 0 &&
                    AudioManager.class.getMethod("getCallUplinkInjectionAudioTrack", AudioFormat.class) != null;
        } catch (Throwable failure) { return false; }
    }

    /** Reused only through an already authorized Shizuku Binder socket pair.
     * No network listener or credentials are created by this entry point. */
    public static void serveConnected(InputStream input, OutputStream output, Runnable closeTransport) throws Exception {
    String phase = "CALL_MODE";
    boolean acknowledged = false;
    try {
    if (!inRealCall()) {
        output.write("ERR NOT_IN_CALL\n".getBytes(StandardCharsets.US_ASCII));
        return;
    }

    phase = "FORMAT_INPUT";
    AudioFormat inputFormat = new AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
    phase = "FORMAT_OUTPUT";
    AudioFormat outputFormat = new AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build();

    phase = "DOWNLINK_BUFFER";
    int min = AudioRecord.getMinBufferSize(RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
    if (min <= 0) {
        output.write("ERR DOWNLINK_BUFFER\n".getBytes(StandardCharsets.US_ASCII));
        return;
    }
    phase = "DOWNLINK_CREATE";
    AudioRecord record = new AudioRecord.Builder()
            .setContext(ProbeRuntime.context())
            .setAudioSource(MediaRecorder.AudioSource.VOICE_DOWNLINK)
            .setAudioFormat(inputFormat)
            .setBufferSizeInBytes(Math.max(4096, min)).build();

    AudioTrack track = null;
    try {
        if (record.getState() != AudioRecord.STATE_INITIALIZED) {
            output.write("ERR DOWNLINK_INIT\n".getBytes(StandardCharsets.US_ASCII));
            return;
        }
        phase = "UPLINK_MANAGER";
        AudioManager manager = ProbeRuntime.context()
                .getSystemService(AudioManager.class);
        phase = "UPLINK_METHOD";
        Method injection = AudioManager.class.getMethod(
                "getCallUplinkInjectionAudioTrack", AudioFormat.class);
        phase = "UPLINK_INVOKE";
        Object stream = injection.invoke(manager, outputFormat);
        if (!(stream instanceof AudioTrack)) {
            output.write("ERR UPLINK_TRACK\n".getBytes(StandardCharsets.US_ASCII));
            return;
        }
        track = (AudioTrack) stream;
        if (track.getState() != AudioTrack.STATE_INITIALIZED) {
            output.write("ERR UPLINK_INIT\n".getBytes(StandardCharsets.US_ASCII));
            return;
        }

        phase = "DOWNLINK_START";
        record.startRecording();
        phase = "UPLINK_PLAY";
        track.play();
        if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
            output.write("ERR DOWNLINK_START\n".getBytes(StandardCharsets.US_ASCII));
            return;
        }
        phase = "HANDSHAKE_ACK";
        output.write("OK\n".getBytes(StandardCharsets.US_ASCII));
        output.flush();
        acknowledged = true;

        final AudioTrack injectionTrack = track;
        AtomicBoolean running = new AtomicBoolean(true);
        long deadline = SystemClock.elapsedRealtime() + MAX_DURATION_MS;
        Thread rx = new Thread(() -> {
            byte[] frame = new byte[FRAME_BYTES];
            try {
                while (running.get() && SystemClock.elapsedRealtime() < deadline) {
                    int offset = 0;
                    while (offset < frame.length) {
                        int n = input.read(frame, offset, frame.length - offset);
                        if (n < 0) throw new IllegalStateException("UPLINK_EOF");
                        offset += n;
                    }
                    int written = 0;
                    while (written < frame.length) {
                        int n = injectionTrack.write(frame, written,
                                frame.length - written, AudioTrack.WRITE_BLOCKING);
                        if (n <= 0) throw new IllegalStateException("UPLINK_WRITE");
                        written += n;
                    }
                }
            } catch (Exception ignored) {
                // Socket closure, phone hang-up or Mac stop; never print audio.
            } finally {
                running.set(false);
                closeTransport.run();
            }
        }, "SIMAI-PCM-Uplink");

        rx.setDaemon(true);
        rx.start();
        byte[] frame = new byte[FRAME_BYTES];
        try {
            while (running.get() && SystemClock.elapsedRealtime() < deadline) {
                if (!inRealCall()) break;
                int offset = 0;
                while (offset < frame.length && running.get()) {
                    int n = record.read(frame, offset,
                            frame.length - offset, AudioRecord.READ_BLOCKING);
                    if (n < 0) throw new IllegalStateException("DOWNLINK_READ");
                    if (n == 0) continue;
                    offset += n;
                }
                if (offset == frame.length) output.write(frame);
            }
        } catch (Exception ignored) {
            // All failures close the socket and release both tracks.
        } finally {
            running.set(false);
            closeTransport.run();
            try { rx.join(1500); } catch (InterruptedException ignored) {}
        }
    } finally {
        try { record.stop(); } catch (Exception ignored) {}
        record.release();
        if (track != null) {
            try { track.stop(); } catch (Exception ignored) {}
            track.release();
        }
    }
    } catch (Throwable failure) {
        if (!acknowledged) {
            // Only a fixed stage and exception category cross the
            // socket; never include OS exception text or call data.
            String code = "INIT_" + phase + "_" + failureCategory(failure);
            try {
                output.write(("ERR " + code + "\n").getBytes(StandardCharsets.US_ASCII));
                output.flush();
            } catch (Exception ignored) { }
        }
    }
    }

    private static String failureCategory(Throwable throwable) {
        Throwable cause = throwable;
        for (int i = 0; i < 4 && cause.getCause() != null; i++)
            cause = cause.getCause();
        if (cause instanceof SecurityException) return "PERMISSION";
        if (cause instanceof NoSuchMethodException) return "API_MISSING";
        if (cause instanceof IllegalStateException) return "ILLEGAL_STATE";
        if (cause instanceof IllegalArgumentException) return "ARGUMENT";
        if (cause instanceof java.io.IOException) return "IO_ERROR";
        return "ANDROID_EXCEPTION";
    }

    private static String readHeader(InputStream stream) throws Exception {
        byte[] data = new byte[90];
        int used = 0;
        while (used < data.length) {
            int c = stream.read();
            if (c < 0) break;
            if (c == '\n') break;
            if (c < 32 || c > 126) return "";
            data[used++] = (byte) c;
        }
        return used < data.length
                ? new String(data, 0, used, StandardCharsets.US_ASCII) : "";
    }

    private static boolean inRealCall() throws Exception {
        AudioManager manager = ProbeRuntime.context().getSystemService(AudioManager.class);
        int mode = manager.getMode();
        return mode == AudioManager.MODE_IN_CALL
                || mode == MODE_SCREENING || mode == MODE_REDIRECT;
    }
}
