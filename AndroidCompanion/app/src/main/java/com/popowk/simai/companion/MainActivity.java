package com.popowk.simai.companion;

import android.Manifest;
import android.app.Activity;
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

/** User-facing test panel. All potentially sensitive actions require a tap. */
public final class MainActivity extends Activity {
    private static final int PHONE_PERMISSION_REQUEST = 1021;
    private static final int SMS_PERMISSION_REQUEST = 1022;
    private TextView state;
    private TextView log;
    private TextView permission;
    private TextView smsStatus;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable update = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 900);
        }
    };

    @Override public void onCreate(Bundle stateBundle) {
        super.onCreate(stateBundle);
        ScrollView scroller = new ScrollView(this);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(20 * getResources().getDisplayMetrics().density);
        column.setPadding(pad, pad, pad, pad);
        scroller.addView(column);

        TextView title = new TextView(this);
        title.setText("SIM AI Companion · V0.3.2");
        title.setTextSize(22f);
        column.addView(title);
        TextView description = new TextView(this);
        description.setText("\nAndroid 电话状态 + 飞书短信通知 · 不接听、不录音、不读取来电号码。\n保留 vivo 原来的拨号应用与蓝牙功能。\n");
        column.addView(description);

        permission = new TextView(this);
        column.addView(permission);
        Button grant = new Button(this);
        grant.setText("授权电话状态读取");
        grant.setOnClickListener(v -> requestPermissions(
                new String[]{Manifest.permission.READ_PHONE_STATE}, PHONE_PERMISSION_REQUEST));
        column.addView(grant);

        state = new TextView(this);
        state.setTextSize(18);
        column.addView(state);
        Button start = new Button(this);
        start.setText("开始监听电话状态");
        start.setOnClickListener(v -> {
            if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.READ_PHONE_STATE}, PHONE_PERMISSION_REQUEST);
                return;
            }
            Intent service = new Intent(this, CallMonitorService.class);
            try {
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
                else startService(service);
            } catch (Exception exception) {
                CallMonitorService.note("无法启动监听：" + exception.getClass().getSimpleName());
            }
            refresh();
        });
        column.addView(start);

        Button stop = new Button(this);
        stop.setText("停止监听");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, CallMonitorService.class));
            refresh();
        });
        column.addView(stop);

        CheckBox stayAwake = new CheckBox(this);
        stayAwake.setText("锁屏运行增强（可选，增加耗电）");
        stayAwake.setChecked(getSharedPreferences(CallMonitorService.PREFS, MODE_PRIVATE)
                .getBoolean(CallMonitorService.KEEP_AWAKE, false));
        stayAwake.setOnCheckedChangeListener((buttonView, enabled) -> {
            getSharedPreferences(CallMonitorService.PREFS, MODE_PRIVATE).edit()
                    .putBoolean(CallMonitorService.KEEP_AWAKE, enabled).apply();
            if (CallMonitorService.running) {
                try {
                    startService(new Intent(this, CallMonitorService.class));
                } catch (Exception error) {
                    CallMonitorService.note("锁屏运行设置应用失败：" + error.getClass().getSimpleName());
                }
            }
            refresh();
        });
        column.addView(stayAwake);

        TextView stayAwakeHelp = new TextView(this);
        stayAwakeHelp.setText("锁屏运行增强只维持电话状态监听进程的 CPU 唤醒锁（服务运行时），不点亮屏幕，也不能绕过系统对无线 ADB/Doze 的限制。长期启用会增加电量消耗。建议先在 vivo 系统设置中将本应用设为允许后台运行/自启动。");
        column.addView(stayAwakeHelp);
        Button batterySettings = new Button(this);
        batterySettings.setText("打开本应用系统设置 · 检查电池/后台权限");
        batterySettings.setOnClickListener(v -> {
            Intent settings = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName()));
            startActivity(settings);
        });
        column.addView(batterySettings);

        // SMS receiver does not depend on the foreground call monitor/ADB;
        // it is off in practice until the user grants the Android permission
        // and manually provides a valid official Feishu bot HTTPS endpoint.
        TextView smsTitle = new TextView(this);
        smsTitle.setText("\n短信转发至飞书 Webhook");
        smsTitle.setTextSize(20);
        column.addView(smsTitle);

        TextView smsHelp = new TextView(this);
        smsHelp.setText("新收到的短信将保留全文及发送方，通过 HTTPS 推送到你配置的飞书群机器人，包含验证码等敏感信息。开关默认开启；但必须先在本机授予短信接收权限并设置飞书 Webhook，才会实际发送。仅限你本人管理的私人飞书群，请勿公开 Webhook。无需 Mac、ADB 或电话监听服务常驻。");
        column.addView(smsHelp);

        CheckBox smsEnabled = new CheckBox(this);
        smsEnabled.setText("自动转发新短信（默认开启）");
        smsEnabled.setChecked(SmsWebhookForwarder.isEnabled(this));
        smsEnabled.setOnCheckedChangeListener((buttonView, value) -> {
            SmsWebhookForwarder.setEnabled(this, value);
            refresh();
        });
        column.addView(smsEnabled);

        Button smsPermissionButton = new Button(this);
        smsPermissionButton.setText("授权接收短信（Android 系统弹窗）");
        smsPermissionButton.setOnClickListener(v ->
                requestPermissions(new String[]{Manifest.permission.RECEIVE_SMS},
                        SMS_PERMISSION_REQUEST));
        column.addView(smsPermissionButton);

        EditText webhookInput = new EditText(this);
        webhookInput.setHint("粘贴飞书自定义机器人 Webhook（https://open.feishu.cn/...）");
        webhookInput.setInputType(InputType.TYPE_CLASS_TEXT |
                InputType.TYPE_TEXT_VARIATION_PASSWORD);
        webhookInput.setSingleLine(true);
        column.addView(webhookInput);

        EditText signatureInput = new EditText(this);
        signatureInput.setHint("飞书签名密钥（可选，留空则保留已有密钥）");
        signatureInput.setInputType(InputType.TYPE_CLASS_TEXT |
                InputType.TYPE_TEXT_VARIATION_PASSWORD);
        signatureInput.setSingleLine(true);
        column.addView(signatureInput);

        Button saveWebhook = new Button(this);
        saveWebhook.setText("保存飞书 Webhook 和签名设置");
        saveWebhook.setOnClickListener(v -> {
            String url = webhookInput.getText().toString().trim();
            String secret = signatureInput.getText().toString();
            if (!SmsWebhookForwarder.configure(this, url, secret, !secret.isEmpty())) {
                Toast.makeText(this, "地址无效：仅允许官方飞书机器人 HTTPS Webhook",
                        Toast.LENGTH_LONG).show();
                return;
            }
            webhookInput.setText("");
            signatureInput.setText("");
            Toast.makeText(this, "已安全保存配置，短信内容不会写入日志", Toast.LENGTH_SHORT).show();
            refresh();
        });
        column.addView(saveWebhook);

        Button clearWebhook = new Button(this);
        clearWebhook.setText("清除飞书 Webhook / 签名（立即停止实际转发）");
        clearWebhook.setOnClickListener(v -> {
            new android.app.AlertDialog.Builder(this)
                    .setTitle("清除短信推送配置？")
                    .setMessage("这会清除手机本应用保存的 Webhook 地址和签名密钥；无法再转发短信，直到你重新配置。")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("确认清除", (dialog, which) -> {
                        SmsWebhookForwarder.clearConfiguration(this);
                        webhookInput.setText("");
                        signatureInput.setText("");
                        refresh();
                    }).show();
        });
        column.addView(clearWebhook);

        Button testWebhook = new Button(this);
        testWebhook.setText("发送一条不含验证码的测试消息");
        testWebhook.setOnClickListener(v -> {
            testWebhook.setEnabled(false);
            SmsWebhookForwarder.sendTest(this, () ->
                handler.post(() -> {
                    testWebhook.setEnabled(true);
                    refresh();
                }));
        });
        column.addView(testWebhook);

        smsStatus = new TextView(this);
        column.addView(smsStatus);
        TextView smsFootnote = new TextView(this);
        smsFootnote.setText("安全提醒：飞书群成员均可能看到短信全文与验证码。建议启用机器人签名校验。即使开关为开启，未授权短信权限或 Webhook 为空时都不会向外发送。应用不读取历史短信、不保存正文、不写入诊断 ZIP；Android 系统对部分短信和省电后台策略可能有限制。\n");
        column.addView(smsFootnote);

        TextView caution = new TextView(this);
        caution.setText("\n拨打测试：用另一部手机拨打本机联通 SIM，检查 RINGING → OFFHOOK → IDLE。\n后台省电限制可能中止监听服务。USB 或无线 ADB 授权后，Mac 会读取匿名来电状态。锁屏运行增强需要用户明确勾选；不保证无线 ADB 锁屏后始终可用。\n");
        column.addView(caution);
        log = new TextView(this);
        log.setTextIsSelectable(true);
        column.addView(log);

        setContentView(scroller);
    }

    private void refresh() {
        permission.setText("电话权限：" + (checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
            == PackageManager.PERMISSION_GRANTED ? "已授权" : "未授权"));
        state.setText("服务：" + (CallMonitorService.running ? "运行中" : "停止")
                + "   状态：" + CallMonitorService.lastState);
        if (smsStatus != null) {
            boolean smsGranted = checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                    == PackageManager.PERMISSION_GRANTED;
            smsStatus.setText("短信权限：" + (smsGranted ? "已授权" : "未授权") +
                    " · 自动转发：" + (SmsWebhookForwarder.isEnabled(this) ? "开启" : "关闭") +
                    " · 飞书地址：" + (SmsWebhookForwarder.hasConfiguration(this) ? "已配置" : "未配置") +
                    "\n最近发送结果：" + SmsWebhookForwarder.status(this));
        }
        log.setText("最近事件（不保存号码）：\n" +
                String.join("\n", CallMonitorService.eventSnapshot()));
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                                     int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == SMS_PERMISSION_REQUEST) {
            boolean granted = checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                    == PackageManager.PERMISSION_GRANTED;
            Toast.makeText(this, granted
                    ? "短信接收权限已授权；配置 Webhook 后可自动发送新短信"
                    : "短信权限未获授权。部分 Android 设备会限制侧载应用的短信权限，请检查系统权限与安装来源",
                    Toast.LENGTH_LONG).show();
        }
        refresh();
    }

    @Override protected void onResume() {
        super.onResume();
        handler.removeCallbacks(update);
        handler.post(update);
    }
    @Override protected void onPause() {
        handler.removeCallbacks(update);
        super.onPause();
    }
}
