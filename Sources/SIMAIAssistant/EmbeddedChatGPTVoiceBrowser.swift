#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import WebKit
import SIMAICore

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
    @Published var destinationDraft =
        UserDefaults.standard.string(forKey: "SIMAI_CHATGPT_FIXED_URL") ?? ChatGPTDestination.home
    @Published private(set) var rememberMicrophoneApproval =
        UserDefaults.standard.object(forKey: "SIMAI_REMEMBER_CHATGPT_MIC") as? Bool ?? true
    private let micApprovalKey = "SIMAI_CHATGPT_MIC_PREVIOUSLY_APPROVED"
    // Unlike the previous "remember after successful capture" option,
    // this explicit site-level choice is always visible in BOTH windows.
    @Published private(set) var alwaysAllowOfficialMicrophone =
        UserDefaults.standard.bool(forKey: "SIMAI_CHATGPT_MIC_ALWAYS_ALLOW")

    func setAlwaysAllowOfficialMicrophone(_ allowed: Bool) {
        alwaysAllowOfficialMicrophone = allowed
        UserDefaults.standard.set(allowed, forKey: "SIMAI_CHATGPT_MIC_ALWAYS_ALLOW")
        // Off always means ASK, even when an older release remembered success.
        status = allowed
            ? "本站麦克风已设为始终允许（仅 chatgpt.com）；macOS 系统权限仍生效"
            : "本站麦克风已改为每次询问；不会再自动授权网页"
        onDiagnostic?(allowed ? "VOICE_SITE_MIC_ALWAYS_ALLOWED" : "VOICE_SITE_MIC_ASK_EACH_TIME")
    }

    var configuredURL: URL {
        ChatGPTDestination.validated(
            UserDefaults.standard.string(forKey: "SIMAI_CHATGPT_FIXED_URL") ?? ""
        ) ?? URL(string: ChatGPTDestination.home)!
    }

    /// Saving is limited to official HTTPS ChatGPT pages. No content, tokens
    /// or conversation text are inspected or included in diagnostics.
    @discardableResult
    func saveDestination() -> Bool {
        guard let selected = ChatGPTDestination.validated(destinationDraft) else {
            status = "网址不合规：仅支持 chatgpt.com 的 HTTPS 页面，不允许账号信息或查询参数"
            return false
        }
        let previous = configuredURL
        UserDefaults.standard.set(selected.absoluteString, forKey: "SIMAI_CHATGPT_FIXED_URL")
        destinationDraft = selected.absoluteString
        if loaded && !microphoneActive && previous != selected {
            webView.load(URLRequest(url: selected))
            status = "已保存固定网址并重新打开指定 ChatGPT 页面"
        } else {
            status = microphoneActive
                ? "固定网址已保存；当前 Voice 不受影响，下次打开自动使用"
                : "固定网址已保存；后续来电自动从这个地址启动"
        }
        return true
    }

    func setRememberMicrophoneApproval(_ enabled: Bool) {
        rememberMicrophoneApproval = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_REMEMBER_CHATGPT_MIC")
        if !enabled {
            UserDefaults.standard.removeObject(forKey: micApprovalKey)
            status = "不再记住网站麦克风许可；下次使用会重新请求确认"
        } else {
            status = "已开启许可记忆；在网页首次同意麦克风后才自动记住"
        }
    }

    // Merely constructing WKWebView can allocate WebKit processes. Keep
    // the whole web view lazy until an incoming call or manual sign-in.
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Media autoplay is not equivalent to microphone permission.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()
    var onMicrophoneChange: ((Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var lastStartAttempt = Date.distantPast
    private var previousCaptureState: WKMediaCaptureState = .none

    /// Muting the mic is not the same as ending Voice. In particular,
    /// WKWebView can report .muted while the Voice session is still alive.
    var voiceSessionActuallyEnded: Bool {
        loaded && webView.microphoneCaptureState == .none
    }

    private var isOfficialPage: Bool {
        let url = webView.url
        return url?.scheme?.lowercased() == "https" &&
            url?.host?.lowercased() == "chatgpt.com"
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        let url = configuredURL
        loaded = true
        webView.load(URLRequest(url: url,
                                cachePolicy: .useProtocolCachePolicy))
        status = "正在载入已保存的 ChatGPT 页面；首次使用请自行登录"
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
        previousCaptureState = .none
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
        let captureState = webView.microphoneCaptureState
        let active = captureState == .active
        guard captureState != previousCaptureState ||
              active != microphoneActive else { return }
        previousCaptureState = captureState
        microphoneActive = active
        if active && isOfficialPage && rememberMicrophoneApproval {
            // Save only after WebKit confirms a real active capture resulting
            // from the site's permission flow; never pre-grant on first use.
            UserDefaults.standard.set(true, forKey: micApprovalKey)
        }
        status = active
            ? "WebKit 已确认 ChatGPT 正在采集麦克风"
            : captureState == .muted
                ? "Voice 麦克风已静音，语音会话不等于结束"
                : "Voice 已停止使用麦克风；正在判断是否应同步挂断电话"
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
        guard loaded else { return }
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
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // The user must authorize capture in the WebKit/macOS permission
        // prompt. Never automatically grant microphone to an auth provider.
        if origin.protocol == "https" && origin.host == "chatgpt.com" &&
           type == .microphone {
            // Explicitly user-configured website permission, analogous to a
            // browser's "Always allow microphone" setting. macOS TCC consent
            // still applies and can be revoked in System Settings.
            if alwaysAllowOfficialMicrophone {
                decisionHandler(.grant)
                onDiagnostic?("VOICE_SITE_MIC_GRANT")
            } else {
                decisionHandler(.prompt)
                onDiagnostic?("VOICE_MIC_PERMISSION_PROMPT")
            }
        } else {
            // Never silently authorize camera capture or third-party hosts.
            decisionHandler(.deny)
            onDiagnostic?("VOICE_MEDIA_PERMISSION_RESTRICTED")
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
                    NSWorkspace.shared.open(browser.configuredURL)
                }
            }
            HStack {
                TextField("固定 ChatGPT 网址（例如自定义 GPT 或已有对话）",
                          text: $browser.destinationDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("固定 ChatGPT 页面地址")
                Button("保存网址") { browser.saveDestination() }
                    .buttonStyle(.borderedProminent)
            }
            Toggle("网站权限：始终允许 ChatGPT 使用麦克风", isOn: Binding(
                get: { browser.alwaysAllowOfficialMicrophone },
                set: { browser.setAlwaysAllowOfficialMicrophone($0) }
            ))
            .font(.headline)
            Text("仅授权官方 chatgpt.com 的麦克风，不授权摄像头；关闭后每次询问。macOS 系统的首次麦克风授权依然需要确认。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("登录后自动尝试启动 Voice（实验）", isOn: Binding(
                get: { browser.automaticVoiceButtonEnabled },
                set: { model.setEmbeddedVoiceAutoStart($0) }
            ))
            Text(browser.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("固定网址只允许官方 chatgpt.com（可选自定义 GPT／会话），不读取提示词。上方网站麦克风开关就是浏览器层面的允许/询问设置；macOS 系统隐私权限单独管理。")
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
