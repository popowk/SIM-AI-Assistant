#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import WebKit

/// An opt-in, *experimental* browser for the public ChatGPT website.
/// No passwords, cookies, auth tokens, chat messages, speech, or page HTML
/// are read into this app or diagnostics. WebKit owns persistent sign-in.
@MainActor
final class EmbeddedChatGPTVoiceBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var status = "首次使用请在内嵌网页自行登录 ChatGPT"
    @Published private(set) var microphoneActive = false
    @Published private(set) var loaded = false
    @Published var automaticVoiceButtonEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_EMBEDDED_VOICE_AUTOCLICK") as? Bool ?? true

    let webView: WKWebView
    var onMicrophoneChange: ((Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var lastStartAttempt = Date.distantPast

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // WebRTC can still require an OS prompt and a real browser gesture.
        // This property only configures media autoplay, not mic authorization.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private var isOfficialPage: Bool {
        let url = webView.url
        return url?.scheme?.lowercased() == "https" &&
            url?.host?.lowercased() == "chatgpt.com"
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        guard let url = URL(string: "https://chatgpt.com/") else { return }
        loaded = true
        webView.load(URLRequest(url: url,
                                cachePolicy: .useProtocolCachePolicy))
        status = "正在载入 chatgpt.com；首次使用请在网页自行登录"
    }

    func reload() {
        if loaded { webView.reload() }
        else { loadIfNeeded() }
    }

    /// Unload the official web application between calls to release page,
    /// WebRTC and JavaScript resources. Persistent WebKit sign-in is kept;
    /// WebKit may retain shared process memory until macOS reclaims it.
    func releaseForIdle() {
        guard loaded else { return }
        loaded = false
        lastStartAttempt = .distantPast
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        if microphoneActive {
            microphoneActive = false
            onMicrophoneChange?(false)
        }
        status = "空闲省内存：ChatGPT 网页已卸载，登录数据保留"
        onDiagnostic?("VOICE_PAGE_UNLOADED_IDLE")
    }

    func setAutomaticVoiceButton(_ enabled: Bool) {
        automaticVoiceButtonEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_EMBEDDED_VOICE_AUTOCLICK")
        if enabled {
            status = "实验性自动启动已开启；仅在 ChatGPT 官方网页尝试 Voice 按钮"
        } else {
            status = "网页自动点击已关闭；可在内嵌窗口手动启动 Voice"
        }
    }

    func checkMicrophoneCapture() {
        let active = webView.microphoneCaptureState == .active
        guard active != microphoneActive else { return }
        microphoneActive = active
        status = active
            ? "WebKit 已确认 chatgpt.com 正在采集麦克风；不代表 GPT 已收到有效声音"
            : "网页麦克风采集已停止；新的来电不会自动接听"
        onDiagnostic?(active ? "VOICE_WEBKIT_CAPTURE_ACTIVE" : "VOICE_WEBKIT_CAPTURE_INACTIVE")
        onMicrophoneChange?(active)
    }

    /// Called by the existing once-per-2s app health loop. Avoid frequent
    /// DOM activity, and only try while the user opted into experimentation.
    func healthCheck(prepareAudio: () -> Bool) {
        guard loaded else { return }
        checkMicrophoneCapture()
        guard automaticVoiceButtonEnabled && isOfficialPage &&
              !microphoneActive &&
              Date().timeIntervalSince(lastStartAttempt) > 10 else { return }
        guard prepareAudio() else {
            status = "BlackHole 2ch／16ch 未准备好；未点击 Voice"
            return
        }
        attemptVoiceStart()
    }

    /// Only clicks a *visible* Voice-start control on the official origin.
    /// No hidden API, credential access, token reuse, authentication bypass,
    /// CAPTCHA interaction, transcription extraction, or login automation.
    /// The web app can change its UI or reject programmatic media gestures.
    func attemptVoiceStart() {
        loadIfNeeded()
        guard isOfficialPage else {
            status = "请先完成 ChatGPT 登录；当前不是 chatgpt.com 页面"
            return
        }
        guard !microphoneActive else { return }
        lastStartAttempt = Date()
        let script = """
        (() => {
          if (location.protocol !== 'https:' || location.hostname !== 'chatgpt.com')
            return 'VOICE_ORIGIN_BLOCKED';
          const options = Array.from(document.querySelectorAll('button,[role="button"]'));
          for (const el of options) {
            const label = [
              el.getAttribute('aria-label') || '',
              el.getAttribute('title') || '',
              el.getAttribute('data-testid') || '',
              (el.textContent || '').trim().slice(0, 70)
            ].join(' ').trim();
            if (!label) continue;
            if (/end|stop|leave|mute|close|hang up|结束|停止|关闭|静音|挂断/i.test(label))
              continue;
            const likelyStart = /(^|\\s)(start voice|use voice|voice mode|voice chat|语音模式|开始语音|语音对话)(\\s|$)/i.test(label);
            const exactVoice = /^(voice|语音)$/i.test(label);
            const testId = el.getAttribute('data-testid') || '';
            const knownButton = /voice[-_](mode|start|button)/i.test(testId);
            if (!likelyStart && !exactVoice && !knownButton)
              continue;
            if (el.disabled || el.getAttribute('aria-disabled') === 'true')
              continue;
            const r = el.getBoundingClientRect();
            if (!r.width || !r.height) continue;
            el.click();
            return 'VOICE_BUTTON_CLICK_ATTEMPTED';
          }
          return 'VOICE_BUTTON_NOT_FOUND';
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    self.status = "网页拒绝实验性 Voice 点击；请在窗口中手动启动"
                    self.onDiagnostic?("VOICE_SCRIPT_REJECTED")
                } else if let result = result as? String, result == "VOICE_BUTTON_CLICK_ATTEMPTED" {
                    self.status = "已尝试点击官方 Voice 按钮；正在等待网页麦克风真正激活"
                    self.onDiagnostic?("VOICE_BUTTON_CLICK_ATTEMPTED")
                } else {
                    self.status = "网页未找到兼容的 Voice 启动按钮；请手动点击，可能是网站已更新"
                    self.onDiagnostic?("VOICE_BUTTON_NOT_FOUND")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status = isOfficialPage
            ? "ChatGPT 页面已加载；可以在这里登录或开启 Voice"
            : "正在完成网页登录；部分 Google／SSO 方式不支持内嵌浏览器"
        checkMicrophoneCapture()
        // The next 2s health tick may attempt startup, but only after
        // a real owner has enabled the experimental auto-click setting.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        status = "内嵌网页加载失败；请检查网络，或改用外部浏览器"
        onDiagnostic?("VOICE_WEBVIEW_LOAD_FAILED")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        status = "登录或网页连接失败；嵌入式登录可能受到安全限制"
        onDiagnostic?("VOICE_WEBVIEW_NAVIGATION_FAILED")
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // This application deliberately has no editable URL bar. Never let
        // an unrelated website mimic ChatGPT's sign-in page within the app.
        // Preserve OpenAI-controlled authentication redirects; third-party
        // login providers and external links use the user's real browser.
        if url.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        let approved = host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") ||
                       host == "openai.com" || host.hasSuffix(".openai.com")
        if approved {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            status = "第三方网站已在系统浏览器打开；外部登录会话无法自动回写到 WebKit"
            onDiagnostic?("VOICE_EXTERNAL_ORIGIN_OPENED")
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // The user must authorize capture in the WebKit/macOS permission
        // prompt. Never automatically grant microphone to an auth provider.
        if origin.protocol == "https" && origin.host == "chatgpt.com" {
            decisionHandler(.prompt)
            onDiagnostic?("VOICE_MIC_PERMISSION_PROMPT")
        } else {
            decisionHandler(.deny)
            onDiagnostic?("VOICE_MIC_UNTRUSTED_ORIGIN_DENIED")
        }
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // An external authentication popup must remain in a trusted browser;
        // don't copy credentials or OAuth cookies from Safari back into WebKit.
        if let url = navigationAction.request.url, url.scheme == "https" {
            NSWorkspace.shared.open(url)
            status = "已在系统浏览器打开登录跳转；如无法返回内嵌网页，请使用邮箱登录或外部网页"
        }
        return nil
    }
}

struct EmbeddedChatGPTWebView: NSViewRepresentable {
    @ObservedObject var controller: EmbeddedChatGPTVoiceBrowser
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct EmbeddedChatGPTVoiceWindow: View {
    @EnvironmentObject private var model: AssistantModel
    @ObservedObject var browser: EmbeddedChatGPTVoiceBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ChatGPT Voice · 内嵌浏览器")
                    .font(.headline)
                Spacer()
                Button("重新加载") { browser.reload() }
                Button("实验性启动 Voice") { model.tryStartEmbeddedVoice() }
                    .disabled(!browser.loaded)
                Button("外部浏览器打开") {
                    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
                }
            }
            Toggle("登录后自动尝试启动 Voice（实验）", isOn: Binding(
                get: { browser.automaticVoiceButtonEnabled },
                set: { model.setEmbeddedVoiceAutoStart($0) }
            ))
            Text(browser.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("只保存在本机 WebKit 网站数据中登录。不会获取密码、Cookie、Token 或对话内容。首次麦克风授权须由你确认；Google 登录可能拒绝内嵌浏览器。网页改版或无用户手势时，自动点击可能失败。")
                .font(.caption)
                .foregroundStyle(.secondary)
            EmbeddedChatGPTWebView(controller: browser)
                .onAppear { browser.loadIfNeeded() }
                .onDisappear {
                    if model.livePhoneState == "IDLE" {
                        browser.releaseForIdle()
                    }
                }
                .frame(minHeight: 500)
        }
        .padding(12)
        .onAppear { browser.loadIfNeeded() }
    }
}
#endif
