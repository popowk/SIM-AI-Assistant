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
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** User-facing test panel. All potentially sensitive actions require a tap. */
public final class MainActivity extends Activity {
    private static final int PHONE_PERMISSION_REQUEST = 1021;
    private TextView state;
    private TextView log;
    private TextView permission;
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
        title.setText("SIM AI Companion · V0.2.1");
        title.setTextSize(22f);
        column.addView(title);
        TextView description = new TextView(this);
        description.setText("\nAndroid 电话状态测试 · 不接听、不录音、不读取来电号码。\n保留 vivo 原来的拨号应用与蓝牙功能。\n");
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
        log.setText("最近事件（不保存号码）：\n" +
                String.join("\n", CallMonitorService.eventSnapshot()));
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
