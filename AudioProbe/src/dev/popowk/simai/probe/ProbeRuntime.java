package dev.popowk.simai.probe;

import android.app.Application;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;
import android.os.Looper;
import android.os.Process;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;

/**
 * Minimal shell-user Android framework bootstrap.
 * Inspired by scrcpy and the Apache-2.0/MIT PhoneBridge implementation;
 * see THIRD_PARTY_NOTICES.md. No root, service installation, or privilege escalation.
 */
final class ProbeRuntime {
    private static Context context;
    static synchronized Context context() throws Exception {
        if (context != null) return context;
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> ctor = at.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object thread = ctor.newInstance();
        put(at, null, "sCurrentActivityThread", thread);
        put(at, thread, "mSystemThread", true);

        Class<?> bd = Class.forName("android.app.ActivityThread$AppBindData");
        Constructor<?> bdCtor = bd.getDeclaredConstructor();
        bdCtor.setAccessible(true);
        Object bound = bdCtor.newInstance();
        ApplicationInfo info = new ApplicationInfo();
        info.packageName = "com.android.shell";
        put(bd, bound, "appInfo", info);
        put(at, thread, "mBoundApplication", bound);

        Context system = (Context) at.getDeclaredMethod("getSystemContext").invoke(thread);
        context = new ShellContext(system);
        Application application = new Application();
        put(ContextWrapper.class, application, "mBase", context);
        put(at, thread, "mInitialApplication", application);
        return context;
    }

    private static void put(Class<?> type, Object object, String name, Object value) throws Exception {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        field.set(object, value);
    }

    private static final class ShellContext extends ContextWrapper {
        ShellContext(Context base) { super(base); }
        @Override public String getPackageName() { return "com.android.shell"; }
        @Override public String getOpPackageName() { return "com.android.shell"; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(Process.myUid())
                    .setPackageName("com.android.shell").build();
        }
        @Override public Context getApplicationContext() { return this; }
    }
}
