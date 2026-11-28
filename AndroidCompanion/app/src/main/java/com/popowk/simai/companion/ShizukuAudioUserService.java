package com.popowk.simai.companion;

import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.system.Os;
import android.system.OsConstants;
import android.media.AudioManager;
import android.media.AudioFormat;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import dev.popowk.simai.probe.AudioStreamServer;

/** Dedicated, non-exported Shizuku UserService. Receives only an app-owned
 * Binder socket pair; never listens on the LAN and accepts no shell commands. */
public final class ShizukuAudioUserService extends IShizukuAudio.Stub {
    private ParcelFileDescriptor active;

    public ShizukuAudioUserService() {}

    @Override public int probe() {
        if (Build.VERSION.SDK_INT < 33 || (Process.myUid() != 2000 && Process.myUid() != 0)) return 0;
        try {
            return AudioStreamServer.shellAudioAvailable() ? 1 : 0; // Actual call audio is verified on connect.
        } catch (Throwable failure) { return 0; }
    }

    @Override public synchronized boolean startAudio(ParcelFileDescriptor socket) {
        if (socket == null || active != null || probe() != 1) {
            if (socket != null) try { socket.close(); } catch (Exception ignored) {}
            return false;
        }
        active = socket;
        Thread worker = new Thread(() -> {
            try {
                AudioStreamServer.serveConnected(new FileInputStream(socket.getFileDescriptor()),
                    new FileOutputStream(socket.getFileDescriptor()), () -> shutdown(socket));
            } catch (Throwable failure) {
                // Never export samples, call details or exception messages.
            } finally {
                shutdown(socket);
                try { socket.close(); } catch (Exception ignored) {}
                synchronized (this) { if (active == socket) active = null; }
            }
        }, "SIMAI-Shizuku-PCM");
        worker.setDaemon(true);
        worker.start();
        return true;
    }

    private static void shutdown(ParcelFileDescriptor socket) {
        try { Os.shutdown(socket.getFileDescriptor(), OsConstants.SHUT_RDWR); } catch (Exception ignored) {}
    }

    @Override public synchronized void destroy() {
        if (active != null) {
            shutdown(active);
            try { active.close(); } catch (Exception ignored) {}
            active = null;
        }
        System.exit(0);
    }
}
