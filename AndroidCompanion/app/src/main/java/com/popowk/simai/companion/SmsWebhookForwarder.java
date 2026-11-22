package com.popowk.simai.companion;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.io.InputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Receives only NEW incoming SMS via the OS protected SMS_RECEIVED broadcast.
 * Does not read the inbox, require READ_SMS, send texts, or persist SMS bodies.
 * This receiver is independent of the caller-state service and Mac/ADB.
 *
 * Configuration is stored in Android's app-private SharedPreferences. The
 * switch defaults ON, but real forwarding requires an on-device SMS runtime
 * grant and a separately configured, strictly validated HTTPS Feishu webhook.
 */
public final class SmsWebhookForwarder extends BroadcastReceiver {
    static final String PREFS = "simai_sms_feishu";
    static final String KEY_ENABLED = "forward_enabled";
    static final String KEY_WEBHOOK = "feishu_webhook";
    static final String KEY_SECRET = "feishu_signing_secret";
    private static final String KEY_LAST_STATUS = "last_delivery_status";
    private static final String KEY_LAST_TIME = "last_delivery_time";

    private static final String TAG = "SIMAI-SMS";
    private static final int MAX_BODY_CHARS = 65536;
    // Mac can push this file into the debug app sandbox via the ADB stdin
    // stream. It contains credentials and is never exposed through a URL.
    private static final String ADB_PENDING_CONFIG = "simai-feishu-sync.json";
    private static final Object CONFIG_LOCK = new Object();
    private static final ThreadPoolExecutor SENDER = new ThreadPoolExecutor(
            1, 1, 10L, TimeUnit.SECONDS, new ArrayBlockingQueue<>(4),
            runnable -> {
                Thread worker = new Thread(runnable, "SIMAI-Feishu-SMS");
                worker.setDaemon(true);
                return worker;
            });
    private static final Map<String, Long> recent = new LinkedHashMap<>();

    public static boolean isEnabled(Context context) {
        applyPendingADBSettings(context);
        return prefs(context).getBoolean(KEY_ENABLED, true);
    }

    public static boolean hasConfiguration(Context context) {
        applyPendingADBSettings(context);
        return validWebhook(prefs(context).getString(KEY_WEBHOOK, ""));
    }

    static void setEnabled(Context context, boolean enabled) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply();
    }

    static boolean configure(Context context, String webhook, String secret, boolean updateSecret) {
        if (!validWebhook(webhook)) return false;
        SharedPreferences.Editor edit = prefs(context).edit().putString(KEY_WEBHOOK, webhook.trim());
        if (updateSecret) edit.putString(KEY_SECRET, secret == null ? "" : secret);
        return edit.commit();
    }

    static void clearConfiguration(Context context) {
        prefs(context).edit().remove(KEY_WEBHOOK).remove(KEY_SECRET).apply();
    }

    static String status(Context context) {
        applyPendingADBSettings(context);
        SharedPreferences p = prefs(context);
        return p.getString(KEY_LAST_STATUS, "尚未发送") +
                (p.getLong(KEY_LAST_TIME, 0) == 0 ? "" :
                " · " + android.text.format.DateFormat.format(
                        "MM-dd HH:mm:ss", p.getLong(KEY_LAST_TIME, 0)));
    }

    static void sendTest(Context context, Runnable finished) {
        Context app = context.getApplicationContext();
        try {
            SENDER.execute(() -> {
                try {
                    send(app, null, "SIM AI Companion 飞书测试通知（不包含短信或验证码）", true);
                } finally {
                    if (finished != null) finished.run();
                }
            });
        } catch (RejectedExecutionException busy) {
            record(app, "发送繁忙");
            if (finished != null) finished.run();
        }
    }

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())
                || !isEnabled(context) || !hasConfiguration(context)
                || context.checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                        != PackageManager.PERMISSION_GRANTED) return;
        SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null || parts.length == 0) return;
        String sender = parts[0] != null ? parts[0].getOriginatingAddress() : null;
        StringBuilder body = new StringBuilder();
        long timestamp = 0;
        for (SmsMessage part : parts) {
            if (part == null || part.getMessageBody() == null) continue;
            body.append(part.getMessageBody());
            if (timestamp == 0) timestamp = part.getTimestampMillis();
        }
        if (body.length() == 0 || body.length() > MAX_BODY_CHARS) {
            record(context, "短信过长或为空，未转发");
            return;
        }
        String text = body.toString();
        // Avoid duplicate deliveries caused by the same broadcast being
        // dispatched twice. No plaintext is stored in this dedupe cache.
        String fingerprint = Integer.toHexString(Arrays.hashCode(
                (String.valueOf(timestamp) + "\n" + sender + "\n" + text)
                        .getBytes(StandardCharsets.UTF_8)));
        synchronized (recent) {
            long now = System.currentTimeMillis();
            recent.entrySet().removeIf(entry -> now - entry.getValue() > 60_000);
            if (recent.containsKey(fingerprint)) return;
            recent.put(fingerprint, now);
            while (recent.size() > 24) {
                recent.remove(recent.keySet().iterator().next());
            }
        }
        final String finalSender = sender == null ? "(未知发送方)" : sender;
        Context app = context.getApplicationContext();
        PendingResult pending = goAsync();
        try {
            SENDER.execute(() -> {
                try {
                    send(app, finalSender, text, false);
                } finally {
                    pending.finish();
                }
            });
        } catch (RejectedExecutionException busy) {
            record(app, "发送繁忙，未转发");
            pending.finish();
        }
    }

    /**
     * Import a configuration written by the authorized ADB user into
     * app-private preferences. This runs before inspecting new SMS, so no
     * phone-call monitor service or Mac daemon must remain running.
     *
     * The file is created mode 0600 by run-as, consumed exactly once, and
     * deleted after commit. Secrets are never printed to logcat.
     */
    private static void applyPendingADBSettings(Context context) {
        synchronized (CONFIG_LOCK) {
            File pending = new File(context.getFilesDir(), ADB_PENDING_CONFIG);
            if (!pending.isFile()) return;
            try {
                if (pending.length() < 2 || pending.length() > 4096) {
                    pending.delete();
                    return;
                }
                byte[] bytes;
                try (FileInputStream in = new FileInputStream(pending);
                     ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[1024];
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        output.write(buffer, 0, read);
                        if (output.size() > 4096) return;
                    }
                    bytes = output.toByteArray();
                }
                JSONObject settings = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
                String webhook = settings.optString("webhook", "");
                String secret = settings.optString("secret", "");
                Object enabled = settings.opt("enabled");
                if (!validWebhook(webhook) || secret.getBytes(StandardCharsets.UTF_8).length > 256
                        || !(enabled instanceof Boolean)) {
                    pending.delete();
                    return;
                }
                SharedPreferences.Editor editor = prefs(context).edit()
                        .putString(KEY_WEBHOOK, webhook.trim())
                        .putString(KEY_SECRET, secret)
                        .putBoolean(KEY_ENABLED, (Boolean) enabled);
                if (editor.commit()) pending.delete();
            } catch (Exception ignored) {
                // Do not emit exception messages, raw JSON or secrets.
                Log.w(TAG, "ADB SMS settings import failed");
            }
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /**
     * Restrict the destination to an official Feishu/Lark custom-bot HTTPS URL.
     * Never follow redirects, accept a different host, cleartext, credentials,
     * nonstandard ports, or query-string redirects.
     */
    static boolean validWebhook(String input) {
        if (input == null || input.length() > 512) return false;
        try {
            URI uri = new URI(input.trim());
            String host = uri.getHost();
            String path = uri.getPath();
            return "https".equalsIgnoreCase(uri.getScheme())
                    && host != null
                    && ("open.feishu.cn".equalsIgnoreCase(host)
                        || "open.larksuite.com".equalsIgnoreCase(host))
                    && (uri.getPort() == -1 || uri.getPort() == 443)
                    && uri.getUserInfo() == null && uri.getQuery() == null
                    && uri.getFragment() == null
                    && path != null
                    && path.matches("/open-apis/bot/v2/hook/[a-zA-Z0-9-]{8,100}");
        } catch (Exception invalid) {
            return false;
        }
    }

    private static void send(Context context, String sender, String text, boolean test) {
        applyPendingADBSettings(context);
        if (!test && (!isEnabled(context) ||
                context.checkSelfPermission(Manifest.permission.RECEIVE_SMS)
                        != PackageManager.PERMISSION_GRANTED)) return;
        SharedPreferences p = prefs(context);
        String webhook = p.getString(KEY_WEBHOOK, "");
        if (!validWebhook(webhook)) {
            record(context, "Webhook 未配置");
            return;
        }
        HttpURLConnection connection = null;
        try {
            // Keep the entire SMS body, including any one-time code and line
            // breaks, intact. Only the display heading/sender are added.
            String content = test ? text : "【SIM AI 短信通知】\n发送方：" + sender + "\n短信全文：\n" + text;
            JSONObject payload = new JSONObject();
            payload.put("msg_type", "text");
            payload.put("content", new JSONObject().put("text", content));

            String signingSecret = p.getString(KEY_SECRET, "");
            if (signingSecret != null && !signingSecret.isEmpty()) {
                String timestamp = Long.toString(System.currentTimeMillis() / 1000);
                Mac mac = Mac.getInstance("HmacSHA256");
                mac.init(new SecretKeySpec((timestamp + "\n" + signingSecret)
                        .getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
                payload.put("timestamp", timestamp);
                payload.put("sign", Base64.encodeToString(
                        mac.doFinal(new byte[0]), Base64.NO_WRAP));
            }
            byte[] data = payload.toString().getBytes(StandardCharsets.UTF_8);
            connection = (HttpURLConnection) new URL(webhook.trim()).openConnection();
            connection.setInstanceFollowRedirects(false);
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(4000);
            connection.setReadTimeout(4000);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            connection.setRequestProperty("Accept", "application/json");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(data.length);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(data);
            }
            int http = connection.getResponseCode();
            if (http != 200) {
                record(context, "发送失败：HTTP " + http);
                return;
            }
            // Feishu may return HTTP 200 even when bot security checks reject
            // the post. Only treat an explicit code=0/StatusCode=0 as success.
            String response;
            try (InputStream stream = connection.getInputStream()) {
                byte[] buffer = new byte[4096];
                int n = stream.read(buffer);
                response = n > 0 ? new String(buffer, 0, n, StandardCharsets.UTF_8) : "";
            }
            JSONObject result = new JSONObject(response);
            int code = result.has("code") ? result.optInt("code", -1) :
                    result.optInt("StatusCode", -1);
            record(context, code == 0 ? (test ? "测试发送成功" : "短信已转发") :
                    "飞书拒绝请求（代码 " + code + "）");
        } catch (Exception error) {
            // Never log URL, signing secret, sender, SMS text or response body.
            record(context, "发送失败：" + error.getClass().getSimpleName());
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static void record(Context context, String status) {
        prefs(context).edit().putString(KEY_LAST_STATUS, status)
                .putLong(KEY_LAST_TIME, System.currentTimeMillis()).apply();
        Log.i(TAG, status);
    }
}
