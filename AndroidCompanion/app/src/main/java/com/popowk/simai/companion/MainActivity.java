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
    private static final int ANSWER_PERMISSION_REQUEST = 1023;
    private static final String ONBOARDING_PREFS = "simai_initial_setup";
    private static final String KEY_WIZARD_SHOWN = "permissions_wizard_shown";
    private static final String KEY_MONITOR_DESIRED = "phone_state_monitor_desired";
    private boolean wizardInProgress = false;
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
        title.setText("SIM AI Companion · V0.3.6");
        title.setTextSize(22f);
        column.addView(title);
        TextView description = new TextView(this);
        description.setText("\nAndroid 电话状态 + 飞书短信通知 + Mac 接听／结束自动电话（可选授权）。\n默认不自动接听；保留 vivo 原来的拨号应用与蓝牙功能。\n");
        column.addView(description);

        permission = new TextView(this);
        column.addView(permission);
        Button grant = new Button(this);
        grant.setText("授权电话状态读取");
        grant.setOnClickListener(v -> requestPhonePermissionAndAutoStart());
        column.addView(grant);

        Button answerGrant = new Button(this);
        answerGrant.setText("授权 Mac 控制接听与结束电话（可选）");
        answerGrant.setOnClickListener(v ->
                new android.app.AlertDialog.Builder(this)
                        .setTitle("允许 Mac 管理接听及结束通话？")
                        .setMessage("授权后，Mac 端可以在 Voice 已就绪时请求自动接听；对于本应用自动接听且会话校验一致的电话，Voice 结束后可以请求结束通话。不会改为默认拨号应用，不会记录来电号码。")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("继续系统授权", (dialog, which) -> requestPermissions(
                                new String[]{Manifest.permission.ANSWER_PHONE_CALLS},
                                ANSWER_PERMISSION_REQUEST)).show());
        column.addView(answerGrant);

        state = new TextView(this);
        state.setTextSize(18);
        column.addView(state);
        Button start = new Button(this);
        start.setText("开始监听电话状态");
        start.setOnClickListener(v -> {
            setMonitorDesired(true);
            requestPhonePermissionAndAutoStart();
        });
        column.addView(start);

        Button stop = new Button(this);
        stop.setText("停止监听");
        stop.setOnClickListener(v -> {
            setMonitorDesired(false);
            stopService(new Intent(this, CallMonitorService.class));
            refresh();
        });
        column.addView(stop);

        CheckBox stayAwake = new CheckBox(this);
        stayAwake.setText("锁屏运行增强（新安装默认开启，增加耗电）");
        stayAwake.setChecked(getSharedPreferences(CallMonitorService.PREFS, MODE_PRIVATE)
                .getBoolean(CallMonitorService.KEEP_AWAKE, true));
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
        stayAwakeHelp.setText("新安装默认开启锁屏增强，并保留手动关闭的选择。只维持电话状态监听服务的 CPU 唤醒锁（服务运行时），不点亮屏幕，不能绕过系统对无线 ADB/Doze 的限制。长期启用会增加电量消耗；可到 vivo 设置允许后台运行/自启动。");
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
        smsFootnote.setText("安全提醒：飞书群成员可能看到完整验证码。请使用私有群并开启签名。开关默认开启，但短信系统权限和有效 Webhook 缺一不可。Android 对包含其他应用 SMS Retriever 哈希的验证码可能不发送普通 SMS_RECEIVED 广播，此类短信无法保证自动读取。应用不读取历史收件箱、不保存正文，也不写入诊断 ZIP。\n");
        column.addView(smsFootnote);

        TextView caution = new TextView(this);
        caution.setText("\n拨打测试：用另一部手机拨打本机联通 SIM，检查 RINGING → OFFHOOK → IDLE。\n授权电话状态后会自动启动监听服务，手动点「停止监听」则尊重该选择。后台省电限制可能中止服务；默认启用锁屏运行增强也不能保证无线 ADB 锁屏后始终可用。\n");
        column.addView(caution);
        log = new TextView(this);
        log.setTextIsSelectable(true);
        column.addView(log);

        setContentView(scroller);
        // ADB's installer launches this activity after an install or explicit
        // clean reinstall. Offer one transparent permission wizard, then
        // start the monitor after Android actually grants the phone permission.
        handler.post(() -> {
            if (monitorDesired() &&
                    checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                            == PackageManager.PERMISSION_GRANTED) startPhoneMonitorIfAllowed();
            offerFirstRunSetup();
        });
    }

    private boolean monitorDesired() {
        return getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE)
                .getBoolean(KEY_MONITOR_DESIRED, true);
    }

    private void setMonitorDesired(boolean desired) {
        getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE).edit()
                .putBoolean(KEY_MONITOR_DESIRED, desired).apply();
    }

    private void startPhoneMonitorIfAllowed() {
        if (!monitorDesired() || CallMonitorService.running ||
                checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                        != PackageManager.PERMISSION_GRANTED) return;
        try {
            Intent service = new Intent(this, CallMonitorService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
            else startService(service);
        } catch (Exception exception) {
            CallMonitorService.note("自动启动监听失败：" + exception.getClass().getSimpleName());
        }
        refresh();
    }

    private void requestPhonePermissionAndAutoStart() {
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                == PackageManager.PERMISSION_GRANTED) {
            startPhoneMonitorIfAllowed();
            if (wizardInProgress) requestSMSPermissionIfNeeded();
        } else {
            requestPermissions(new String[]{Manifest.permission.READ_PHONE_STATE},
                    PHONE_PERMISSION_REQUEST);
        }
    }

    private void requestSMSPermissionIfNeeded() {
        if (!wizardInProgress) return;
        if (checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                == PackageManager.PERMISSION_GRANTED) {
            wizardInProgress = false;
            refresh();
            return;
        }
        requestPermissions(new String[]{Manifest.permission.RECEIVE_SMS},
                SMS_PERMISSION_REQUEST);
    }

    private void offerFirstRunSetup() {
        android.content.SharedPreferences setup =
                getSharedPreferences(ONBOARDING_PREFS, MODE_PRIVATE);
        if (setup.getBoolean(KEY_WIZARD_SHOWN, false)) return;
        setup.edit().putBoolean(KEY_WIZARD_SHOWN, true).apply();
        new android.app.AlertDialog.Builder(this)
                .setTitle("安装完成 · 自动初始化")
                .setMessage("应用将默认启用锁屏运行增强和自动短信通知。下一步会由 Android 依次请求「电话状态」与「接收短信」权限；授予电话权限后将自动启动电话状态监听。\n\n短信转发仅在收到系统 SMS 广播、已获得短信权限、且你配置了飞书机器人时发生；包含验证码的全文会发送给你指定的飞书群。部分定向验证码不会向本应用广播。是否现在开始系统授权？")
                .setPositiveButton("开始授权并启动", (dialog, which) -> {
                    wizardInProgress = true;
                    requestPhonePermissionAndAutoStart();
                })
                .setNegativeButton("稍后手动授权", (dialog, which) -> {
                    wizardInProgress = false;
                    refresh();
                })
                .show();
    }

    private void refresh() {
        permission.setText("电话状态权限：" + (checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
            == PackageManager.PERMISSION_GRANTED ? "已授权" : "未授权") +
            " · Mac 人工接听：" + (checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
            == PackageManager.PERMISSION_GRANTED ? "已授权" : "未授权（可选）"));
        state.setText("服务：" + (CallMonitorService.running ? "运行中" : "停止")
                + "   状态：" + CallMonitorService.lastState);
        if (smsStatus != null) {
            boolean smsGranted = checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                    == PackageManager.PERMISSION_GRANTED;
            smsStatus.setText("短信权限：" + (smsGranted ? "已授权" : "未授权") +
                    " · 自动转发：" + (SmsWebhookForwarder.isEnabled(this) ? "开启" : "关闭") +
                    " · 飞书地址：" + (SmsWebhookForwarder.hasConfiguration(this) ? "已配置" : "未配置") +
                    "\n收到普通短信广播：" + SmsWebhookForwarder.receivedBroadcastCount(this) +
                    " 次（最近：" + SmsWebhookForwarder.lastBroadcastDescription(this) + "）" +
                    "\n最近发送结果：" + SmsWebhookForwarder.status(this));
        }
        log.setText("最近事件（不保存号码）：\n" +
                String.join("\n", CallMonitorService.eventSnapshot()));
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                                     int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PHONE_PERMISSION_REQUEST) {
            boolean granted = checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                    == PackageManager.PERMISSION_GRANTED;
            if (granted) {
                startPhoneMonitorIfAllowed();
            } else {
                Toast.makeText(this, "系统未授权电话状态；可在应用设置中手动开启",
                        Toast.LENGTH_LONG).show();
            }
            if (wizardInProgress) requestSMSPermissionIfNeeded();
        } else if (requestCode == ANSWER_PERMISSION_REQUEST) {
            Toast.makeText(this,
                    checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
                            == PackageManager.PERMISSION_GRANTED
                    ? "电话接听／结束权限已授权；仅允许用户启用的自动值守或人工操作"
                    : "人工接听权限未获授权；原有电话与短信功能不受影响",
                    Toast.LENGTH_LONG).show();
        } else if (requestCode == SMS_PERMISSION_REQUEST) {
            wizardInProgress = false;
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
        // If the user granted phone permission through Android Settings, also
        // resume the previously requested monitor without an extra tap.
        if (monitorDesired() && !CallMonitorService.running &&
                checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                        == PackageManager.PERMISSION_GRANTED) {
            startPhoneMonitorIfAllowed();
        }
    }
    @Override protected void onPause() {
        handler.removeCallbacks(update);
        super.onPause();
    }
}
