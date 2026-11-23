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
    @Published private(set) var isolatedAudioOutputEnabled = true
    @Published private(set) var isolatedOutputReady = false
    @Published private(set) var isolatedMicrophoneReady = false
    @Published private(set) var isolatedMicrophoneStatus = "等待确认 ChatGPT 实际录音设备为 BlackHole 2ch"
    var onIsolatedMicrophoneChange: ((Bool) -> Void)?
    private var lastMicrophoneRouteCheck = Date.distantPast
    @Published private(set) var playbackBlocked = false
    private var lastPlaybackCheck = Date.distantPast
    @Published private(set) var isolatedOutputStatus = "等待 Voice 网页创建独立声音通道"
    var onIsolatedOutputChange: ((Bool) -> Void)?
    private var isolateCheckBusy = false
    private var lastIsolationCheck = Date.distantPast

    func setIsolatedAudioOutputEnabled(_ enabled: Bool) {
        isolatedAudioOutputEnabled = enabled
        if !enabled { updateIsolatedOutputReady(false) }
        else if loaded { routeCurrentVoiceAudioIfNeeded(force: true) }
    }

    private func updateIsolatedMicrophoneReady(_ ready: Bool) {
        guard isolatedMicrophoneReady != ready else { return }
        isolatedMicrophoneReady = ready
        onIsolatedMicrophoneChange?(ready)
    }

    private func updateIsolatedOutputReady(_ ready: Bool) {
        guard isolatedOutputReady != ready else { return }
        isolatedOutputReady = ready
        onIsolatedOutputChange?(ready)
    }
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
        // Route only this WKWebView's audio elements, NOT the whole Mac.
        // When a target sink is known, postpone HTMLMediaElement.play()
        // until the device has been selected. Failure does not fall back
        // to system output, protecting unrelated movie audio.
        let isolatedMediaScript = #"""
        (() => {
          if (location.protocol !== 'https:' || location.hostname !== 'chatgpt.com') return;
          if (window.__simaiAudioIsolationInstalled) return;
          window.__simaiAudioIsolationInstalled = true;
          window.__simaiAudioSinkID = '';
          window.__simaiAudioElements = new Set();
          // The previous version only checked WKWebView capture ACTIVE.
          // This proves *a* mic was running, not that the caller's BlackHole
          // 2ch was selected. Constrain the actual official page getUserMedia
          // request, and refuse to hand a wrong input stream to the website.
          window.__simaiMicRouteCode = 'WAITING_FOR_CAPTURE';
          window.__simaiMicTracks = new Set();
          if (navigator.mediaDevices &&
              typeof navigator.mediaDevices.getUserMedia === 'function') {
            const originalCapture =
              navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
            const originalDevices =
              navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
            navigator.mediaDevices.getUserMedia = async function(request) {
              if (!request || !request.audio) return originalCapture(request);
              window.__simaiMicRouteCode = 'BLACKHOLE2_CHECKING';
              // Do not await enumerateDevices() BEFORE the native capture:
              // that can lose a real user gesture and make WebKit reject
              // microphone access. The first call uses our prepared macOS
              // BlackHole2 default input. Later calls use a cached exact ID.
              const audioConstraints = request.audio === true
                ? {} : {...request.audio};
              if (window.__simaiBlackHole2DeviceId) {
                audioConstraints.deviceId =
                  {exact: window.__simaiBlackHole2DeviceId};
              }
              let stream;
              try {
                const immediateCapture = originalCapture(
                  {...request, audio: audioConstraints});
                stream = await immediateCapture;
              } catch (err) {
                window.__simaiMicRouteCode = 'BLACKHOLE2_CAPTURE_FAILED';
                throw err;
              }
              // WebKit reveals audio device labels after the site captures.
              // Confirm the actual track before delivering it to ChatGPT.
              let updated = [];
              try { updated = await originalDevices(); } catch (_) {}
              const target = updated.find(d => d.kind === 'audioinput'
                && (d.label || '').toLowerCase().includes('blackhole 2ch'));
              const tracks = stream.getAudioTracks();
              const matching = !!target && tracks.length > 0 &&
                tracks.every(t => t.readyState === 'live' &&
                  ((t.getSettings && t.getSettings().deviceId === target.deviceId)
                    || (t.label || '').toLowerCase().includes('blackhole 2ch')));
              if (target && target.deviceId) {
                window.__simaiBlackHole2DeviceId = target.deviceId;
              }
              if (!matching) {
                tracks.forEach(t => t.stop());
                window.__simaiMicRouteCode =
                  target ? 'WRONG_CAPTURE_DEVICE' : 'BLACKHOLE2_NOT_VISIBLE';
                throw new DOMException('Expected BlackHole 2ch input', 'NotFoundError');
              }
              tracks.forEach(t => {
                window.__simaiMicTracks.add(t);
                t.addEventListener('ended', () => window.__simaiMicTracks.delete(t));
              });
              window.__simaiMicRouteCode = 'BLACKHOLE2_CAPTURE_VERIFIED';
              return stream;
            };
          } else {
            window.__simaiMicRouteCode = 'VOICE_CAPTURE_UNSUPPORTED';
          }

          // Preserve the site's real click user activation. The prior
          // setSinkId(...).then(() => play()) deferred play past the trusted
          // gesture and could cause NotAllowedError ("tap to play").
          // Never delay the site's own play() behind a Promise.
          window.__simaiAutoplayBlocked = false;
          const nativePlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function(...args) {
            if (window.__simaiAudioElements.size < 200) {
              window.__simaiAudioElements.add(this);
            }
            const sink = window.__simaiAudioSinkID;
            if (sink && typeof this.setSinkId === 'function'
                && this.sinkId !== sink) {
              try { Promise.resolve(this.setSinkId(sink)).catch(() => {}); }
              catch (_) {}
            }
            const playback = nativePlay.apply(this, args);
            if (playback && typeof playback.catch === 'function') {
              playback.catch(error => {
                if (error && error.name === 'NotAllowedError') {
                  window.__simaiAutoplayBlocked = true;
                }
              });
            }
            return playback;
          };
          for (const event of ['pointerdown','keydown','touchstart']) {
            document.addEventListener(event, e => {
              if (e.isTrusted) window.__simaiAutoplayBlocked = false;
            }, true);
          }
        })();
        """#
        configuration.userContentController.addUserScript(WKUserScript(
            source: isolatedMediaScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
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
        lastIsolationCheck = .distantPast
        lastMicrophoneRouteCheck = .distantPast
        updateIsolatedMicrophoneReady(false)
        lastPlaybackCheck = .distantPast
        playbackBlocked = false
        isolateCheckBusy = false
        updateIsolatedOutputReady(false)
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
        if active {
            checkActualMicrophoneRouting(force: true)
        } else {
            updateIsolatedMicrophoneReady(false)
        }
        if active && isolatedAudioOutputEnabled {
            routeCurrentVoiceAudioIfNeeded(force: true)
        } else if !active {
            updateIsolatedOutputReady(false)
        }
        onMicrophoneChange?(active)
    }

    /// Verify which microphone ChatGPT really received, rather than using
    /// WKWebView's generic microphone-capture indicator as proof. No audio,
    /// device IDs, account contents or transcripts ever leave the webpage.
    func checkActualMicrophoneRouting(force: Bool = false) {
        guard loaded, isOfficialPage, microphoneActive,
              force || Date().timeIntervalSince(lastMicrophoneRouteCheck) >= 2 else { return }
        lastMicrophoneRouteCheck = Date()
        let script = #"""
        (() => {
          const code = window.__simaiMicRouteCode || 'MIC_HOOK_MISSING';
          const tracks = [...(window.__simaiMicTracks || [])];
          const live = tracks.some(t => t.readyState === 'live');
          return code === 'BLACKHOLE2_CAPTURE_VERIFIED' && live
            ? 'BLACKHOLE2_CAPTURE_VERIFIED' : live ? 'MIC_NOT_VERIFIED' : code;
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor [weak self] in
                guard let self, self.loaded else { return }
                let code = error == nil ? (value as? String ?? "MIC_CHECK_FAILED")
                                        : "MIC_CHECK_FAILED"
                let verified = code == "BLACKHOLE2_CAPTURE_VERIFIED"
                self.updateIsolatedMicrophoneReady(verified)
                let message: [String: String] = [
                    "BLACKHOLE2_CAPTURE_VERIFIED": "ChatGPT 正在使用 BlackHole 2ch 采集电话声音",
                    "WAITING_FOR_CAPTURE": "等待 ChatGPT 网页开始录音",
                    "BLACKHOLE2_CHECKING": "正在确认 ChatGPT 输入设备",
                    "BLACKHOLE2_NOT_VISIBLE": "网页未识别 BlackHole 2ch；不能确认 GPT 能听到电话",
                    "WRONG_CAPTURE_DEVICE": "网页选中了错误麦克风，已停止该音轨以防混入环境声音",
                    "BLACKHOLE2_CAPTURE_FAILED": "BlackHole 2ch 录音请求失败",
                    "VOICE_CAPTURE_UNSUPPORTED": "网页不支持受控麦克风采集",
                    "MIC_HOOK_MISSING": "网页麦克风隔离尚未安装",
                ]
                self.isolatedMicrophoneStatus = message[code] ?? "麦克风未通过验证（\(code)）"
                if verified || force { self.onDiagnostic?(code) }
            }
        }
    }

    /// Best effort per-page speaker selection supported by macOS WebKit.
    /// This inspects ONLY audio device labels and active media elements; it
    /// does not read ChatGPT text, cookies, microphone samples or WebRTC data.
    /// We never claim a working route based only on an available API.
    func routeCurrentVoiceAudioIfNeeded(force: Bool = false) {
        guard loaded, isolatedAudioOutputEnabled, isOfficialPage,
              microphoneActive, !isolateCheckBusy,
              force || Date().timeIntervalSince(lastIsolationCheck) >= 2 else { return }
        isolateCheckBusy = true
        lastIsolationCheck = Date()
        let functionBody = #"""
        if (location.protocol !== 'https:' || location.hostname !== 'chatgpt.com') {
          return {code:'ORIGIN_NOT_ALLOWED'};
        }
        if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
          return {code:'MEDIA_DEVICES_UNAVAILABLE'};
        }
        if (typeof HTMLMediaElement.prototype.setSinkId !== 'function') {
          return {code:'SET_SINK_UNSUPPORTED'};
        }
        let devices;
        try { devices = await navigator.mediaDevices.enumerateDevices(); }
        catch (_) { return {code:'ENUMERATE_OUTPUT_FAILED'}; }
        const target = devices.find(d => d.kind === 'audiooutput'
          && (d.label || '').toLowerCase().includes('blackhole 16ch'));
        if (!target || !target.deviceId) {
          return {code:'BLACKHOLE16_NOT_LISTED'};
        }
        // Includes detached Audio() objects which registered at play().
        window.__simaiAudioSinkID = target.deviceId;
        const set = new Set([
          ...document.querySelectorAll('audio, video'),
          ...(window.__simaiAudioElements || [])
        ]);
        let count = 0, unsupported = 0, failed = 0;
        for (const node of set) {
          if (!(node instanceof HTMLMediaElement)) continue;
          const tracks = node.srcObject && typeof node.srcObject.getAudioTracks === 'function'
            ? node.srcObject.getAudioTracks() : [];
          // Only a real audio stream/playing media can confirm Voice output.
          if (!tracks.length && (node.paused || node.readyState === 0)) continue;
          if (typeof node.setSinkId !== 'function') { unsupported++; continue; }
          try {
            await node.setSinkId(target.deviceId);
            if (node.sinkId === target.deviceId) count++;
          } catch (_) { failed++; }
        }
        if (count > 0 && failed === 0 && unsupported === 0) {
          return {code:'ISOLATED_WEB_MEDIA_ROUTED'};
        }
        if (failed || unsupported) return {code:'OUTPUT_SELECTION_REJECTED'};
        return {code:'VOICE_REMOTE_MEDIA_NOT_READY'};
        """#
        webView.callAsyncJavaScript(functionBody, arguments: [:], in: nil,
                                    in: .page) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isolateCheckBusy = false
                guard self.loaded && self.isolatedAudioOutputEnabled else { return }
                let code: String
                switch result {
                case .success(let value):
                    code = (value as? [String: Any])?["code"] as? String ??
                        "ISOLATED_OUTPUT_UNKNOWN"
                case .failure:
                    code = "ISOLATED_OUTPUT_SCRIPT_UNSUPPORTED"
                }
                let ready = code == "ISOLATED_WEB_MEDIA_ROUTED"
                self.updateIsolatedOutputReady(ready)
                if ready {
                    self.isolatedOutputStatus =
                        "GPT 网页音频独立输出至 BlackHole 16ch；系统视频不切换"
                } else {
                    let descriptions: [String: String] = [
                        "BLACKHOLE16_NOT_LISTED": "网页未列出 BlackHole 16ch；请确认已安装并授予麦克风权限",
                        "SET_SINK_UNSUPPORTED": "WebKit 不支持该页面的单独输出选择",
                        "VOICE_REMOTE_MEDIA_NOT_READY": "等待 Voice 网页创建可独立路由的声音流",
                        "OUTPUT_SELECTION_REJECTED": "ChatGPT 网页拒绝单独输出；不会改变系统扬声器或自动接听",
                        "ISOLATED_OUTPUT_SCRIPT_UNSUPPORTED": "网页独立音频路由检查失败",
                    ]
                    self.isolatedOutputStatus = descriptions[code] ??
                        "独立 GPT 输出未就绪（" + code + "）"
                }
                // Only a finite list of fixed diagnostics; never include
                // device IDs, media URLs, transcripts or website content.
                if ready || force {
                    self.onDiagnostic?(code)
                }
            }
        }
    }

    /// Report the official webpage's media NotAllowedError without reading
    /// page text or trying to forge a trusted browser gesture.
    private func checkPlaybackPermission() {
        guard loaded, isOfficialPage,
              Date().timeIntervalSince(lastPlaybackCheck) > 3 else { return }
        lastPlaybackCheck = Date()
        webView.evaluateJavaScript("Boolean(window.__simaiAutoplayBlocked)") {
            [weak self] value, error in
            Task { @MainActor [weak self] in
                guard let self, self.loaded, error == nil,
                      let blocked = value as? Bool,
                      blocked != self.playbackBlocked else { return }
                self.playbackBlocked = blocked
                if blocked {
                    self.status = "网页播放受阻：请在 ChatGPT 页面上点击一次继续播放。此问题不是麦克风权限。"
                    self.onDiagnostic?("VOICE_MEDIA_AUTOPLAY_NOT_ALLOWED")
                } else {
                    self.onDiagnostic?("VOICE_MEDIA_PLAYBACK_INTERACTION_RECEIVED")
                }
            }
        }
    }

    /// Called by the existing once-per-2s app health loop. Avoid frequent
    /// DOM activity, and only try while the user opted into experimentation.
    func healthCheck(prepareAudio: () -> Bool) {
        guard loaded else { return }
        checkMicrophoneCapture()
        checkActualMicrophoneRouting()
        checkPlaybackPermission()
        if isolatedAudioOutputEnabled { routeCurrentVoiceAudioIfNeeded() }
        guard automaticVoiceButtonEnabled && isOfficialPage &&
              !playbackBlocked && !microphoneActive &&
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
        updateIsolatedOutputReady(false)
        updateIsolatedMicrophoneReady(false)
        lastIsolationCheck = .distantPast
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
            if browser.isolatedAudioOutputEnabled {
                Label(browser.isolatedMicrophoneReady
                        ? "GPT 已确认使用 BlackHole 2ch 麦克风"
                        : "GPT 输入麦克风尚未通过验证",
                      systemImage: browser.isolatedMicrophoneReady ? "mic.fill" : "mic.slash")
                    .font(.caption.weight(.medium))
                Text(browser.isolatedMicrophoneStatus)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(browser.isolatedOutputReady ? "独立音频路由已就绪" : "独立音频路由待验证",
                          systemImage: browser.isolatedOutputReady
                              ? "checkmark.shield" : "speaker.slash")
                        .font(.caption.weight(.medium))
                    Button("检查 GPT 独立声音输出") {
                        browser.checkMicrophoneCapture()
                        browser.routeCurrentVoiceAudioIfNeeded(force: true)
                    }
                }
                Text(browser.isolatedOutputStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if browser.playbackBlocked {
                Label("ChatGPT 网页要求真人点击播放：请直接点击网页里的“继续播放”。Mac 的网站麦克风许可不能替代网页播放手势。", systemImage: "hand.tap")
                    .font(.caption.weight(.medium))
            }
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
