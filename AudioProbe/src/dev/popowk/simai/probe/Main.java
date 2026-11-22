package dev.popowk.simai.probe;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.IBinder;
import java.lang.reflect.Method;
import java.util.Locale;

/**
 * Explicit, short-lived Android 13+ cellular-call audio compatibility test.
 * No recording files, network listener, device IDs, phone numbers or raw PCM output.
 * "info" is non-invasive. "downlink" reports aggregate sound level for 2 seconds;
 * "uplink" injects a low-volume test tone only after separate Mac-side consent.
 */
public final class Main {
    private static final int RATE = 16000;
    private static final int MODE_CALL_SCREENING = 4;
    private static final int MODE_CALL_REDIRECT = 5;
    private static final String PREFIX = "SIMAI ";
    private Main() {}

    public static void main(String[] args) {
        int exit = 0;
        try {
            if (Build.VERSION.SDK_INT < 33) throw new ProbeError("ANDROID_BELOW_13");
            ProbeRuntime.context();
            String command = args.length == 1 ? args[0] : "invalid";
            switch (command) {
                case "info": info(); break;
                case "downlink": downlink(); break;
                case "uplink": uplink(); break;
                default: throw new ProbeError("INVALID_ACTION");
            }
        } catch (ProbeError e) {
            out("status", "error");
            out("error", e.code);
            exit = 2;
        } catch (Throwable e) {
            out("status", "error");
            out("error", classify(e));
            exit = 3;
        }
        System.out.flush();
        System.exit(exit);
    }

    private static void out(String key, String value) {
        System.out.println(PREFIX + key + "=" + value);
    }

    private static void info() throws Exception {
        AudioManager manager = ProbeRuntime.context().getSystemService(AudioManager.class);
        out("android", Integer.toString(Build.VERSION.SDK_INT));
        out("shell", Integer.toString(android.os.Process.myUid()));
        out("audioMode", Integer.toString(manager.getMode()));
        out("telephonyOutput", telephonyOutput());
        out("pstnInterceptable", interceptable());
        out("downlink", "REQUIRES_REAL_CALL");
        out("uplink", "REQUIRES_REAL_CALL_AND_CONSENT");
        out("status", "ok");
    }

    private static String telephonyOutput() {
        try {
            Method m = AudioManager.class.getDeclaredMethod("getDevicesStatic", int.class);
            m.setAccessible(true);
            AudioDeviceInfo[] devices = (AudioDeviceInfo[]) m.invoke(null, AudioManager.GET_DEVICES_OUTPUTS);
            for (AudioDeviceInfo dev : devices)
                if (dev.getType() == AudioDeviceInfo.TYPE_TELEPHONY) return "true";
            return "false";
        } catch (Exception e) { return "unknown"; }
    }

    private static String interceptable() {
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, "audio");
            Class<?> stub = Class.forName("android.media.IAudioService$Stub");
            Object service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
            Object value = service.getClass().getMethod("isPstnCallAudioInterceptable").invoke(service);
            return Boolean.TRUE.equals(value) ? "true" : "false";
        } catch (Throwable e) { return "unknown"; }
    }

    private static void requireInCall() throws Exception {
        int mode = ProbeRuntime.context().getSystemService(AudioManager.class).getMode();
        if (mode != AudioManager.MODE_IN_CALL && mode != MODE_CALL_SCREENING && mode != MODE_CALL_REDIRECT)
            throw new ProbeError("PHONE_NOT_IN_CALL_AUDIO_MODE");
    }

    private static void downlink() throws Exception {
        requireInCall();
        int buffer = Math.max(AudioRecord.getMinBufferSize(RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), 3200);
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
        AudioRecord record = new AudioRecord.Builder()
                .setContext(ProbeRuntime.context())
                .setAudioSource(MediaRecorder.AudioSource.VOICE_DOWNLINK)
                .setAudioFormat(format).setBufferSizeInBytes(buffer).build();
        int samples = 0;
        int peak = 0;
        double squared = 0;
        try {
            if (record.getState() != AudioRecord.STATE_INITIALIZED)
                throw new ProbeError("DOWNLINK_NOT_INITIALIZED");
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
                throw new ProbeError("DOWNLINK_NOT_RECORDING");
            short[] frame = new short[640];
            long deadline = System.currentTimeMillis() + 2200;
            while (System.currentTimeMillis() < deadline && samples < RATE * 3) {
                int read = record.read(frame, 0, frame.length);
                if (read < 0) throw new ProbeError("DOWNLINK_READ_FAILED");
                if (read == 0) continue;
                for (int i = 0; i < read; i++) {
                    int val = frame[i];
                    peak = Math.max(peak, Math.abs(val));
                    squared += ((double) val) * val;
                }
                samples += read;
            }
            out("status", "ok");
            out("frames", Integer.toString(samples));
            out("peak", String.format(Locale.US, "%.4f", peak / 32768.0));
            out("rms", String.format(Locale.US, "%.5f",
                    samples > 0 ? Math.sqrt(squared / samples) / 32768.0 : 0));
            out("result", samples == 0 ? "NO_FRAMES" : peak == 0 ? "SILENCE" : "NONZERO_PCM");
        } finally {
            try { if (record.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) record.stop(); }
            catch (Throwable ignored) {}
            record.release();
        }
    }

    private static void uplink() throws Exception {
        requireInCall();
        AudioAttributes.Builder builder = new AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
        AudioAttributes.Builder.class.getMethod("setSystemUsage", int.class).invoke(builder, 17);
        AudioAttributes.Builder.class.getMethod("setForCallRedirection").invoke(builder);
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build();
        int min = AudioTrack.getMinBufferSize(RATE,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
        AudioTrack track = new AudioTrack.Builder()
                .setContext(ProbeRuntime.context())
                .setAudioAttributes(builder.build()).setAudioFormat(format)
                .setBufferSizeInBytes(Math.max(min, RATE * 2))
                .setTransferMode(AudioTrack.MODE_STREAM).build();
        try {
            if (track.getState() != AudioTrack.STATE_INITIALIZED)
                throw new ProbeError("UPLINK_NOT_INITIALIZED");
            short[] samples = new short[RATE];
            for (int i = 0; i < RATE; i++) {
                int phase = i % (RATE / 2);
                // Two short gentle test tones with silence between.
                if (phase < RATE / 6)
                    samples[i] = (short) (4500.0 * Math.sin(2 * Math.PI * 660 * i / RATE));
            }
            track.play();
            int offset = 0;
            while (offset < samples.length) {
                int n = track.write(samples, offset, samples.length - offset);
                if (n <= 0) throw new ProbeError("UPLINK_WRITE_FAILED");
                offset += n;
            }
            out("status", "ok");
            out("written", Integer.toString(offset));
            out("result", "TONE_SENT_UNCONFIRMED");
        } finally {
            try { track.stop(); } catch (Throwable ignored) {}
            track.release();
        }
    }

    private static String classify(Throwable e) {
        Throwable cause = e;
        for (int i = 0; i < 4 && cause.getCause() != null; i++) cause = cause.getCause();
        String name = cause.getClass().getSimpleName();
        if (cause instanceof SecurityException) return "PERMISSION_DENIED";
        if (name.contains("NoSuchMethod")) return "API_MISSING";
        if (name.contains("IllegalAccess")) return "HIDDEN_API_BLOCKED";
        if (name.contains("Unsupported")) return "DEVICE_UNSUPPORTED";
        return "ANDROID_" + name.replaceAll("[^A-Za-z0-9_]", "");
    }

    private static class ProbeError extends Exception {
        final String code;
        ProbeError(String code) { super(code); this.code = code; }
    }
}
