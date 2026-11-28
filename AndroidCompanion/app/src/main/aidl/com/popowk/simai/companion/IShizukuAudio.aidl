package com.popowk.simai.companion;
import android.os.ParcelFileDescriptor;
interface IShizukuAudio {
    int probe() = 1;
    boolean startAudio(in ParcelFileDescriptor socket) = 2;
    void destroy() = 16777114;
}
