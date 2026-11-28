package com.popowk.simai.companion;

import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import rikka.shizuku.Shizuku;

/** Companion side of the private Binder audio service. No ADB process on Mac. */
final class ShizukuAudioClient {
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Shizuku.UserServiceArgs args;
    private volatile IShizukuAudio service;
    private volatile boolean verified;
    private volatile boolean enabled;
    private boolean binding;
    private long lastBind;
    private long lastProbe;
    private volatile boolean probing;

    ShizukuAudioClient(Context context) {
        this.context = context.getApplicationContext();
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(),
                ShizukuAudioUserService.class.getName()))
                .daemon(false).processNameSuffix("simai_audio").version(1).debuggable(false);
    }

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            binding = false;
            if (!enabled) return;
            IShizukuAudio candidate = IShizukuAudio.Stub.asInterface(binder);
            service = candidate;
            verified = false;
            probe(candidate);
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            service = null; verified = false; binding = false;
        }
    };

    private void probe(IShizukuAudio candidate) {
        if (candidate == null || probing) return;
        probing = true; lastProbe = SystemClock.elapsedRealtime();
        new Thread(() -> {
            int result = -1;
            try { result = candidate.probe(); } catch (Throwable ignored) {}
            if (service == candidate && enabled) {
                verified = result == 1;
                AndroidDiagnostics.event(context, "SHIZUKU_AUDIO_PROBE", "result=" + result);
            }
            probing = false;
        }, "SIMAI-Shizuku-AudioProbe").start();
    }

    void reconcile(boolean wanted) {
        enabled = wanted;
        main.post(() -> {
            if (!enabled || !ShizukuTelephonyBridge.isReady()) {
                if (service != null || binding) unbind();
                return;
            }
            IShizukuAudio current = service;
            if (current != null && current.asBinder().isBinderAlive()) {
                if (!verified && SystemClock.elapsedRealtime() - lastProbe >= 10000) probe(current);
                return;
            }
            if (current != null) unbind();
            long now = SystemClock.elapsedRealtime();
            if (binding && now - lastBind < 12000) return;
            if (now - lastBind < 3000) return;
            binding = true; lastBind = now;
            try { Shizuku.bindUserService(args, connection); }
            catch (Throwable failure) {
                binding = false; verified = false;
                AndroidDiagnostics.event(context, "SHIZUKU_AUDIO_BIND_FAILURE", "error=" + failure.getClass().getSimpleName());
            }
        });
    }
    private void unbind() {
        service = null; verified = false; binding = false;
        try { Shizuku.unbindUserService(args, connection, true); } catch (Throwable ignored) {}
    }
    boolean ready() {
        IShizukuAudio current = service;
        return enabled && verified && ShizukuTelephonyBridge.isReady() &&
                current != null && current.asBinder().isBinderAlive();
    }
    boolean start(ParcelFileDescriptor fd) {
        IShizukuAudio current = service;
        if (!ready() || current == null) return false;
        try { return current.startAudio(fd); } catch (Throwable ignored) { return false; }
    }
    void stop() { reconcile(false); }
}
