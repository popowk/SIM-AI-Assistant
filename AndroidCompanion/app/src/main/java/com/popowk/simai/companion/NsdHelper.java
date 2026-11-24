package com.popowk.simai.companion;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.util.Log;

/**
 * mDNS (Bonjour) service advertiser for zero-configuration Mac discovery over Wi-Fi.
 */
public final class NsdHelper {
    private static final String TAG = "SIMAINsd";
    private static final String SERVICE_TYPE = "_simai._tcp.";
    private NsdManager nsdManager;
    private NsdManager.RegistrationListener registrationListener;
    private boolean isRegistered = false;

    public synchronized void register(Context context, int port) {
        if (isRegistered) return;
        try {
            nsdManager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
            if (nsdManager == null) return;

            NsdServiceInfo serviceInfo = new NsdServiceInfo();
            String rawModel = Build.MODEL != null ? Build.MODEL : "Android";
            String deviceName = "SIMAI-" + rawModel.replaceAll("[^a-zA-Z0-9-]", "");
            if (deviceName.length() > 30) deviceName = deviceName.substring(0, 30);
            serviceInfo.setServiceName(deviceName);
            serviceInfo.setServiceType(SERVICE_TYPE);
            serviceInfo.setPort(port);

            registrationListener = new NsdManager.RegistrationListener() {
                @Override
                public void onServiceRegistered(NsdServiceInfo nsdServiceInfo) {
                    isRegistered = true;
                    Log.i(TAG, "mDNS Service registered: " + nsdServiceInfo.getServiceName());
                }

                @Override
                public void onRegistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    isRegistered = false;
                    Log.w(TAG, "mDNS Registration failed: " + errorCode);
                }

                @Override
                public void onServiceUnregistered(NsdServiceInfo arg0) {
                    isRegistered = false;
                    Log.i(TAG, "mDNS Service unregistered");
                }

                @Override
                public void onUnregistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    Log.w(TAG, "mDNS Unregistration failed: " + errorCode);
                }
            };

            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener);
        } catch (Throwable t) {
            Log.w(TAG, "Failed to start NSD: " + t.getMessage());
        }
    }

    public synchronized void unregister() {
        if (!isRegistered || nsdManager == null || registrationListener == null) return;
        try {
            nsdManager.unregisterService(registrationListener);
            isRegistered = false;
        } catch (Throwable t) {
            Log.w(TAG, "Failed to unregister NSD: " + t.getMessage());
        }
    }
}
