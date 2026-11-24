package com.popowk.simai.companion;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.net.Uri;
import android.view.View;
import android.text.InputType;
import android.widget.EditText;
import android.widget.Toast;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;

/**
 * SIM AI Companion - Streamlined, unified control panel.
 */
public final class MainActivity extends Activity {
    private static final int ALL_PERMISSIONS_REQUEST = 1020;
    private static final String ONBOARDING_PREFS = "simai_initial_setup";
    private static final String KEY_SETUP_VERSION = "phone_setup_requested_version";
    private static final int CURRENT_SETUP_VERSION = 13;
    private static final String KEY_MONITOR_DESIRED = "phone_state_monitor_desired";

    private TextView statusHeader;
    private TextView wifiStatus;
    private TextView shizukuStatus;
    private Button startOrRestartButton;
    private Button shizukuGrant;
    private TextView smsStatus;
    private TextView log;

    private rikka.shizuku.Shizuku.OnRequestPermissionResultListener shizukuPermissionListener;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable update = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };

    @Override public void onCreate(Bundle stateBundle) {
        super.onCreate(stateBundle);
        ScrollView scroller = new ScrollView(this);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(18 * getResources().getDisplayMetrics().density);
        column.setPadding(pad, pad, pad, pad);
        scroller.addView(column);

        // 1. Title
        String packageVersion = "v0.3.15";
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            packageVersion = "v" + info.versionName + " (Build " + info.versionCode + ")";
        } catch (PackageManager.NameNotFoundException ignored) {}

        TextView title = new TextView(this);
        title.setText("SIM AI Companion · " + packageVersion);
        title.setTextSize(20f);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        column.addView(title);

        // 2. Status Overview
        statusHeader = new TextView(this);
        statusHeader.setTextSize(15f);
        statusHeader.setPadding(0, 16, 0, 8);
        column.addView(statusHeader);

        wifiStatus = new TextView(this);
        wifiStatus.setTextSize(15f);
        wifiStatus.setTypeface(android.graphics.Typeface.MONOSPACE);
        wifiStatus.setPadding(0, 4, 0, 8);
        column.addView(wifiStatus);

        shizukuStatus = new TextView(this);
        shizukuStatus.setTextSize(14f);
        shizukuStatus.setPadding(0, 4, 0, 12);
        column.addView(shizukuStatus);

        // 3. Primary Actions
        startOrRestartButton = new Button(this);
        startOrRestartButton.setText("一键全部授权并启动服务");
        startOrRestartButton.setOnClickListener(v -> {
            setMonitorDesired(true);
            requestAllPermissionsAndAutoStart();
        });
        column.addView(startOrRestartButton);

        shizukuGrant = new Button(this);
        shizukuGrant.setText("授权 Shizuku 特权（免 Root 极速接听／挂断）");
        shizukuGrant.setOnClickListener(v -> ShizukuTelephonyBridge.requestPermission(1030));
        column.addView(shizukuGrant);

        LinearLayout row1 = new LinearLayout(this);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        row1.setPadding(0, 8, 0, 8);

        Button stop = new Button(this);
        stop.setText("停止服务");
        stop.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        stop.setOnClickListener(v -> {
            setMonitorDesired(false);
            stopService(new Intent(this, CallMonitorService.class));
            refresh();
        });
        row1.addView(stop);

        Button batterySettings = new Button(this);
        batterySettings.setText("系统权限/自启动");
        batterySettings.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        batterySettings.setOnClickListener(v -> {
            Intent settings = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName()));
            startActivity(settings);
        });
        row1.addView(batterySettings);
        column.addView(row1);

        CheckBox stayAwake = new CheckBox(this);
        stayAwake.setText("锁屏常驻增强（保持 CPU 唤醒锁）");
        stayAwake.setChecked(getSharedPreferences(CallMonitorService.PREFS, MODE_PRIVATE)
                .getBoolean(CallMonitorService.KEEP_AWAKE, true));
        stayAwake.setOnCheckedChangeListener((buttonView, enabled) -> {
            getSharedPreferences(CallMonitorService.PREFS, MODE_PRIVATE).edit()
                    .putBoolean(CallMonitorService.KEEP_AWAKE, enabled).apply();
            if (CallMonitorService.running) {
                try {
                    startService(new Intent(this, CallMonitorService.class));
                } catch (Exception ignored) {}
            }
            refresh();
        });
        column.addView(stayAwake);

        // 4. SMS Forwarding Section
        TextView smsTitle = new TextView(this);
        smsTitle.setText("\n飞书短信转发设置");
        smsTitle.setTextSize(17f);
        smsTitle.setTypeface(null, android.graphics.Typeface.BOLD);
        column.addView(smsTitle);

        CheckBox smsEnabled = new CheckBox(this);
        smsEnabled.setText("自动转发新收到短信至飞书群机器人");
        smsEnabled.setChecked(SmsWebhookForwarder.isEnabled(this));
        smsEnabled.setOnCheckedChangeListener((buttonView, value) -> {
            SmsWebhookForwarder.setEnabled(this, value);
            refresh();
        });
        column.addView(smsEnabled);

        EditText webhookInput = new EditText(this);
        webhookInput.setHint("飞书 Webhook 地址 (https://open.feishu.cn/...)");
        webhookInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        webhookInput.setSingleLine(true);
        column.addView(webhookInput);

        EditText signatureInput = new EditText(this);
        signatureInput.setHint("飞书签名密钥（可选）");
        signatureInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        signatureInput.setSingleLine(true);
        column.addView(signatureInput);

        LinearLayout smsButtonRow = new LinearLayout(this);
        smsButtonRow.setOrientation(LinearLayout.HORIZONTAL);
        smsButtonRow.setPadding(0, 6, 0, 6);

        Button saveWebhook = new Button(this);
        saveWebhook.setText("保存配置");
        saveWebhook.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        saveWebhook.setOnClickListener(v -> {
            String url = webhookInput.getText().toString().trim();
            String secret = signatureInput.getText().toString();
            if (!SmsWebhookForwarder.configure(this, url, secret, !secret.isEmpty())) {
                Toast.makeText(this, "地址格式无效：必须是官方飞书 HTTPS Webhook", Toast.LENGTH_LONG).show();
                return;
            }
            webhookInput.setText("");
            signatureInput.setText("");
            Toast.makeText(this, "飞书配置已安全保存", Toast.LENGTH_SHORT).show();
            refresh();
        });
        smsButtonRow.addView(saveWebhook);

        Button testWebhook = new Button(this);
        testWebhook.setText("测试发送");
        testWebhook.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        testWebhook.setOnClickListener(v -> {
            testWebhook.setEnabled(false);
            SmsWebhookForwarder.sendTest(this, () ->
                    handler.post(() -> {
                        testWebhook.setEnabled(true);
                        refresh();
                    }));
        });
        smsButtonRow.addView(testWebhook);

        Button clearWebhook = new Button(this);
        clearWebhook.setText("清除");
        clearWebhook.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.7f));
        clearWebhook.setOnClickListener(v -> {
            SmsWebhookForwarder.clearConfiguration(this);
            webhookInput.setText("");
            signatureInput.setText("");
            Toast.makeText(this, "已清除配置", Toast.LENGTH_SHORT).show();
            refresh();
        });
        smsButtonRow.addView(clearWebhook);
        column.addView(smsButtonRow);

        smsStatus = new TextView(this);
        smsStatus.setTextSize(13f);
        smsStatus.setPadding(0, 4, 0, 8);
        column.addView(smsStatus);

        // 5. Recent Events
        TextView logTitle = new TextView(this);
        logTitle.setText("\n最近事件");
        logTitle.setTextSize(16f);
        logTitle.setTypeface(null, android.graphics.Typeface.BOLD);
        column.addView(logTitle);

        log = new TextView(this);
        log.setTextIsSelectable(true);
        log.setTextSize(13f);
        log.setTypeface(android.graphics.Typeface.MONOSPACE);
        column.addView(log);

        setContentView(scroller);

        try {
            shizukuPermissionListener = (req, grantResult) -> handler.post(this::refresh);
            rikka.shizuku.Shizuku.addRequestPermissionResultListener(shizukuPermissionListener);
        } catch (Throwable ignored) {}

        handler.post(() -> {
            if (monitorDesired() && hasCorePermissions()) {
                startPhoneMonitorIfAllowed();
            }
            offerFirstRunSetup();
        });
    }

    private boolean hasCorePermissions() {
        return checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED &&
               checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean monitorDesired() {
        return getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE).getBoolean(KEY_MONITOR_DESIRED, true);
    }

    private void setMonitorDesired(boolean desired) {
        getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE).edit().putBoolean(KEY_MONITOR_DESIRED, desired).apply();
    }

    private void startPhoneMonitorIfAllowed() {
        if (!monitorDesired() || CallMonitorService.running || !hasCorePermissions()) return;
        try {
            Intent service = new Intent(this, CallMonitorService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
            else startService(service);
        } catch (Exception exception) {
            CallMonitorService.note("自动启动监听失败：" + exception.getClass().getSimpleName());
        }
        refresh();
    }

    private void requestAllPermissionsAndAutoStart() {
        ArrayList<String> missing = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.READ_PHONE_STATE);
        }
        if (checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.ANSWER_PHONE_CALLS);
        }
        if (checkSelfPermission(Manifest.permission.RECEIVE_SMS) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.RECEIVE_SMS);
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            missing.add("android.permission.POST_NOTIFICATIONS");
        }

        if (missing.isEmpty()) {
            startPhoneMonitorIfAllowed();
            refresh();
        } else {
            requestPermissions(missing.toArray(new String[0]), ALL_PERMISSIONS_REQUEST);
        }
    }

    private void offerFirstRunSetup() {
        android.content.SharedPreferences setup = getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE);
        if (!monitorDesired()) return;
        if (setup.getInt(KEY_SETUP_VERSION, 0) >= CURRENT_SETUP_VERSION) return;
        setup.edit().putInt(KEY_SETUP_VERSION, CURRENT_SETUP_VERSION).apply();
        requestAllPermissionsAndAutoStart();
    }

    private void refresh() {
        boolean hasPhone = checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED;
        boolean hasAnswer = checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED;
        boolean hasSms = checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED;

        String serviceState = CallMonitorService.running ? "🟢 服务运行中" : "⚪ 服务已停止";
        statusHeader.setText(serviceState + " · 通话状态: " + CallMonitorService.lastState +
                "\n电话权限: " + (hasPhone && hasAnswer ? "已授权" : "未授权") +
                " · 短信权限: " + (hasSms ? "已授权" : "未授权"));

        if (!hasPhone || !hasAnswer || !hasSms) {
            startOrRestartButton.setText("一键全部授权并启动服务");
        } else if (CallMonitorService.running) {
            startOrRestartButton.setText("重启监听服务");
        } else {
            startOrRestartButton.setText("启动监听服务");
        }

        String ip = getLocalIpAddress();
        if (wifiStatus != null) {
            wifiStatus.setText("📶 Wi-Fi 直连: http://" + ip + ":18764\n(Mac 端已支持自动扫描发现，免手动填写)");
        }

        if (shizukuStatus != null) {
            if (ShizukuTelephonyBridge.isReady()) {
                shizukuStatus.setText("🛡️ Shizuku 引擎: 已连接且已授权 (免 Root 特权控制 100% 成功)");
                if (shizukuGrant != null) shizukuGrant.setVisibility(View.GONE);
            } else if (ShizukuTelephonyBridge.isShizukuAvailable()) {
                shizukuStatus.setText("🛡️ Shizuku 引擎: 服务运行中，尚未授权");
                if (shizukuGrant != null) {
                    shizukuGrant.setVisibility(View.VISIBLE);
                    shizukuGrant.setText("授权 Shizuku 特权");
                }
            } else {
                shizukuStatus.setText("🛡️ Shizuku 引擎: 未运行 (可选，启动后可获得免 Root 极速接听)");
                if (shizukuGrant != null) shizukuGrant.setVisibility(View.GONE);
            }
        }

        if (smsStatus != null) {
            smsStatus.setText("转发状态: " + (SmsWebhookForwarder.isEnabled(this) ? "开启" : "关闭") +
                    " · 地址: " + (SmsWebhookForwarder.hasConfiguration(this) ? "已配置" : "未配置") +
                    " · 累计接收: " + SmsWebhookForwarder.receivedBroadcastCount(this) + " 条\n" +
                    "最近结果: " + SmsWebhookForwarder.status(this));
        }

        if (log != null) {
            log.setText(String.join("\n", CallMonitorService.eventSnapshot()));
        }
    }

    private String getLocalIpAddress() {
        try {
            android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager)
                    getApplicationContext().getSystemService(Context.WIFI_SERVICE);
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
                            if (!host.startsWith("127.")) return host;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}
        return "未连接 Wi-Fi";
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (hasCorePermissions()) {
            startPhoneMonitorIfAllowed();
        }
        refresh();
    }

    @Override protected void onResume() {
        super.onResume();
        handler.removeCallbacks(update);
        handler.post(update);
        if (monitorDesired() && !CallMonitorService.running && hasCorePermissions()) {
            startPhoneMonitorIfAllowed();
        }
    }

    @Override protected void onPause() {
        handler.removeCallbacks(update);
        super.onPause();
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        try {
            if (shizukuPermissionListener != null) {
                rikka.shizuku.Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener);
            }
        } catch (Throwable ignored) {}
    }
}
