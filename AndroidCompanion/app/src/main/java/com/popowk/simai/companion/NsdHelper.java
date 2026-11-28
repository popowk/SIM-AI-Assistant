package com.popowk.simai.companion;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.util.Log;

/**
 * mDNS (Bonjour) service advertiser for zero-configuration Mac discovery over Wi-Fi.
 */
public final class NsdHelper {
    private static final String TAG = "SIMAINsd";
    private static final String SERVICE_TYPE = "_simai._tcp";
    private NsdManager nsdManager;
    private NsdManager.RegistrationListener registrationListener;
    private WifiManager.MulticastLock multicastLock;
    private String advertisedIP = "";
    private String advertisedPin = "";
    private volatile boolean isRegistered = false;

    public synchronized void register(Context context, int port, String pin) {
        String wifiIp = getWifiIpAddress(context);
        if (wifiIp == null || wifiIp.isEmpty() || pin == null || !pin.matches("[a-f0-9]{64}")) {
            unregister(); return;
        }
        if (registrationListener != null && wifiIp.equals(advertisedIP) && pin.equals(advertisedPin)) return;
        unregister();
        advertisedIP = wifiIp;
        advertisedPin = pin;
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                try {
                    multicastLock = wm.createMulticastLock("SIMAIMulticastLock");
                    multicastLock.setReferenceCounted(true);
                    multicastLock.acquire();
                } catch (Throwable t) {
                    Log.w(TAG, "Failed to acquire MulticastLock: " + t.getMessage());
                }
            }

            nsdManager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
            if (nsdManager == null) return;

            NsdServiceInfo serviceInfo = new NsdServiceInfo();
            String rawModel = Build.MODEL != null ? Build.MODEL : "Android";
            String deviceName = "SIMAI-" + rawModel.replaceAll("[^a-zA-Z0-9-]", "");
            if (deviceName.length() > 30) deviceName = deviceName.substring(0, 30);
            serviceInfo.setServiceName(deviceName);
            serviceInfo.setServiceType(SERVICE_TYPE);
            serviceInfo.setPort(port);
            serviceInfo.setAttribute("ipv4", wifiIp);
            serviceInfo.setAttribute("port", String.valueOf(port));
            // A public certificate fingerprint is a discovery hint only, never a credential.
            serviceInfo.setAttribute("pin", pin);

            registrationListener = new NsdManager.RegistrationListener() {
                @Override
                public void onServiceRegistered(NsdServiceInfo nsdServiceInfo) {
                    synchronized (NsdHelper.this) {
                        if (registrationListener == this) isRegistered = true;
                    }
                }

                @Override
                public void onRegistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    synchronized (NsdHelper.this) {
                        if (registrationListener == this) { registrationListener = null; isRegistered = false; }
                    }
                    Log.w(TAG, "mDNS Registration failed: " + errorCode);
                }

                @Override
                public void onServiceUnregistered(NsdServiceInfo arg0) {
                    synchronized (NsdHelper.this) {
                        if (registrationListener == this) { registrationListener = null; isRegistered = false; }
                    }
                }

                @Override
                public void onUnregistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    Log.w(TAG, "mDNS Unregistration failed: " + errorCode);
                }
            };

            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener);
        } catch (Throwable t) {
            unregister();
            Log.w(TAG, "Failed to start NSD");
        }
    }

    public synchronized void unregister() {
        NsdManager.RegistrationListener old = registrationListener;
        registrationListener = null;
        advertisedIP = ""; advertisedPin = "";
        if (nsdManager != null && old != null) {
            try {
                nsdManager.unregisterService(old);
            } catch (Throwable t) {
                Log.w(TAG, "Failed to unregister NSD: " + t.getMessage());
            }
            isRegistered = false;
        }
        if (multicastLock != null && multicastLock.isHeld()) {
            try {
                multicastLock.release();
            } catch (Throwable ignored) {}
            multicastLock = null;
        }
    }

    public static String getWifiIpAddress(Context context) {
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                int ipInt = wm.getConnectionInfo().getIpAddress();
                if (ipInt != 0) {
                    return android.text.format.Formatter.formatIpAddress(ipInt);
                }
            }
        } catch (Throwable ignored) {}

        try {
            java.util.List<java.net.NetworkInterface> interfaces =
                    java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces());
            for (java.net.NetworkInterface intf : interfaces) {
                if (!intf.isUp() || intf.isLoopback()) continue;
                String name = intf.getName().toLowerCase();
                if (name.contains("wlan") || name.contains("wifi") || name.contains("eth")) {
                    for (java.net.InetAddress addr : java.util.Collections.list(intf.getInetAddresses())) {
                        if (!addr.isLoopbackAddress() && addr instanceof java.net.Inet4Address) {
                            String host = addr.getHostAddress();
                            if (host != null && !host.startsWith("127.")) return host;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}
        return null;
    }
}
