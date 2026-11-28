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
import android.os.PowerManager;
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
    private long nextMonitorStartAttempt;
    private final Runnable update = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };

    @Override public void onCreate(Bundle stateBundle) {
        super.onCreate(stateBundle);
        AndroidDiagnostics.init(this);
        AndroidDiagnostics.event(this, "ACTIVITY_CREATE", "");
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
        shizukuGrant.setOnClickListener(v -> {
            if (ShizukuTelephonyBridge.isShizukuAvailable()) {
                ShizukuTelephonyBridge.requestPermission(1030);
            } else {
                Intent launch = getPackageManager().getLaunchIntentForPackage("moe.shizuku.privileged.api");
                if (launch != null) {
                    startActivity(launch);
                } else {
                    android.widget.Toast.makeText(this, "手机尚未安装 Shizuku 应用", android.widget.Toast.LENGTH_SHORT).show();
                }
            }
        });
        column.addView(shizukuGrant);

        Button secureWifi = new Button(this);
        secureWifi.setText("重新启用 Shizuku Wi-Fi");
        secureWifi.setOnClickListener(v -> {
            SecurePhoneBridge.enable(this);
            setMonitorDesired(true);
            requestAllPermissionsAndAutoStart();
            refresh();
        });
        column.addView(secureWifi);
        Button disableSecureWifi = new Button(this);
        disableSecureWifi.setText("关闭 Shizuku Wi-Fi 并撤销信任");
        disableSecureWifi.setOnClickListener(v -> {
            new android.app.AlertDialog.Builder(this)
                .setTitle("关闭无线电话连接？")
                .setMessage("已信任的 Mac 将不能再使用 Wi-Fi 通话。USB ADB 不受影响。")
                .setNegativeButton("取消", null)
                .setPositiveButton("关闭并撤销", (dialog, which) -> {
                    SecurePhoneBridge.disable(this);
                    refresh();
                }).show();
        });
        column.addView(disableSecureWifi);

        LinearLayout row1 = new LinearLayout(this);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        row1.setPadding(0, 8, 0, 8);

        Button stop = new Button(this);
        stop.setText("停止服务");
        stop.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        stop.setOnClickListener(v -> {
            setMonitorDesired(false);
            AndroidDiagnostics.event(this, "USER_STOP_MONITOR", "");
            stopService(new Intent(this, CallMonitorService.class));
            refresh();
        });
        row1.addView(stop);

        Button batterySettings = new Button(this);
        batterySettings.setText("电池无限制/自启动");
        batterySettings.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f));
        batterySettings.setOnClickListener(v -> {
            try {
                PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
                if (pm != null && !pm.isIgnoringBatteryOptimizations(getPackageName())) {
                    Intent ignore = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:" + getPackageName()));
                    startActivity(ignore);
                    return;
                }
            } catch (Throwable ignored) {}
            Intent settings = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName()));
            startActivity(settings);
        });
        row1.addView(batterySettings);
        column.addView(row1);

        CheckBox stayAwake = new CheckBox(this);
        stayAwake.setText("锁屏常驻增强（保持 CPU 与 Wi-Fi 后台唤醒）");
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

        Button diagnostics = new Button(this);
        diagnostics.setText("查看手机持久诊断日志");
        diagnostics.setOnClickListener(v -> new android.app.AlertDialog.Builder(this)
                .setTitle("手机诊断（最近100条）")
                .setMessage(AndroidDiagnostics.recent(this))
                .setPositiveButton("关闭", null).show());
        column.addView(diagnostics);
        Button clearLogs = new Button(this);
        clearLogs.setText("清空全部应用日志");
        clearLogs.setOnClickListener(v -> new android.app.AlertDialog.Builder(this)
                .setTitle("清空全部应用日志？")
                .setMessage("不会删除录音、短信设置或 Android 系统日志。")
                .setNegativeButton("取消", null)
                .setPositiveButton("清空", (dialog, which) -> {
                    boolean ok = CallMonitorService.clearDiagnosticHistory(this);
                    android.widget.Toast.makeText(this, ok ? "全部应用日志已清空" : "清理失败",
                            android.widget.Toast.LENGTH_SHORT).show();
                    refresh();
                }).show());
        column.addView(clearLogs);
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
        // Read-only phone state monitoring never requires answering or SMS permissions.
        return checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean monitorDesired() {
        return getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE).getBoolean(KEY_MONITOR_DESIRED, true);
    }

    private void setMonitorDesired(boolean desired) {
        getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE).edit().putBoolean(KEY_MONITOR_DESIRED, desired).apply();
    }

    private void startPhoneMonitorIfAllowed() {
        if (!monitorDesired() || CallMonitorService.running || !hasCorePermissions()) return;
        long now = android.os.SystemClock.elapsedRealtime();
        if (now < nextMonitorStartAttempt) return;
        nextMonitorStartAttempt = now + 5000;
        try {
            Intent service = new Intent(this, CallMonitorService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
            else startService(service);
        } catch (Exception exception) {
            CallMonitorService.note("自动启动监听失败：" + exception.getClass().getSimpleName());
            AndroidDiagnostics.event(this, "MONITOR_START_REQUEST_FAILED", "error=" + exception.getClass().getSimpleName());
        }
        // Do not call refresh() here: it may request start again before the
        // main looper can deliver onStartCommand, causing recursive startup.
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
        startPhoneMonitorIfAllowed();
        boolean hasPhone = checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED;
        boolean hasAnswer = checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED;
        boolean hasSms = checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED;

        String serviceState = CallMonitorService.running ? "🟢 服务运行中" : "⚪ 服务已停止";
        statusHeader.setText(serviceState + " · 通话状态: " + CallMonitorService.lastState +
                "\n来电识别权限: " + (hasPhone ? "已授权" : "未授权") +
                " · 接听权限: " + (hasAnswer ? "已授权" : "未授权") +
                " · 短信权限: " + (hasSms ? "已授权" : "未授权"));

        if (!hasPhone || !hasAnswer || !hasSms) {
            startOrRestartButton.setText("一键全部授权并启动服务");
        } else if (CallMonitorService.running) {
            startOrRestartButton.setText("监听服务运行中");
        } else {
            startOrRestartButton.setText("启动监听服务");
        }

        String ip = getLocalIpAddress();
        if (wifiStatus != null) {
            wifiStatus.setText(!SecurePhoneBridge.isEnabled(this) ? "Wi-Fi 已关闭；可重新启用" :
                ShizukuTelephonyBridge.isReady() ?
                "Shizuku Wi-Fi 自动发现 · " + ip + "\n首次在 Mac 选择无线模式并连接已授权 USB；随后无需数据线。" :
                "Wi-Fi 等待手机 Shizuku 启动并授权");
        }

        if (shizukuStatus != null) {
            if (ShizukuTelephonyBridge.isReady()) {
                ShizukuTelephonyBridge.autoGrantAppPermissions(this);
                shizukuStatus.setText("🛡️ Shizuku 引擎: 已连接且已授权（电话音频需实测）");
                if (shizukuGrant != null) shizukuGrant.setVisibility(View.GONE);
            } else if (ShizukuTelephonyBridge.isShizukuAvailable()) {
                shizukuStatus.setText("🛡️ Shizuku 引擎: 服务运行中，尚未授权");
                if (shizukuGrant != null) {
                    shizukuGrant.setVisibility(View.VISIBLE);
                    shizukuGrant.setText("授权 Shizuku 特权");
                }
            } else {
                shizukuStatus.setText("🛡️ Shizuku 引擎: 未运行 (点击下方按钮打开应用，或在 Mac 端一键启动)");
                if (shizukuGrant != null) {
                    shizukuGrant.setVisibility(View.VISIBLE);
                    shizukuGrant.setText("打开 Shizuku 应用启动服务");
                }
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
        AndroidDiagnostics.event(this, "ACTIVITY_RESUME", "");
        handler.removeCallbacks(update);
        handler.post(update);
        if (monitorDesired() && !CallMonitorService.running && hasCorePermissions()) {
            startPhoneMonitorIfAllowed();
        }
    }

    @Override protected void onPause() {
        AndroidDiagnostics.event(this, "ACTIVITY_PAUSE", "");
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
