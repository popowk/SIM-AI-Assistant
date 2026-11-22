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
final class AudioStreamServer {
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
                if (!inRealCall()) {
                    output.write("ERR NOT_IN_CALL\n".getBytes(StandardCharsets.US_ASCII));
                    return;
                }

                AudioFormat inputFormat = new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
                AudioFormat outputFormat = new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build();

                int min = AudioRecord.getMinBufferSize(RATE,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                if (min <= 0) {
                    output.write("ERR DOWNLINK_BUFFER\n".getBytes(StandardCharsets.US_ASCII));
                    return;
                }
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
                    AudioManager manager = ProbeRuntime.context()
                            .getSystemService(AudioManager.class);
                    Method injection = AudioManager.class.getMethod(
                            "getCallUplinkInjectionAudioTrack", AudioFormat.class);
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

                    record.startRecording();
                    track.play();
                    if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                        output.write("ERR DOWNLINK_START\n".getBytes(StandardCharsets.US_ASCII));
                        return;
                    }
                    output.write("OK\n".getBytes(StandardCharsets.US_ASCII));
                    output.flush();

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
                            try { client.shutdownInput(); } catch (Exception ignored) {}
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
                        try { client.close(); } catch (Exception ignored) {}
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
            }
        }
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
