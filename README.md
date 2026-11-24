# SIM AI Assistant · V0.4.30（系统级接听兜底与 WebRTC 麦克风收音恢复）

> 修复 vivo 及 Android 锁屏下第三方 App 无法自动接听问题（增加 ADB 系统级 Telecom 接听兜底），并恢复 WebKit WebRTC 麦克风 AGC 自动增益与音量归一化，解决电话下行声音无法唤醒 ChatGPT Voice 的问题。

> 09:39 实机诊断确认 v0.4.27 回退仍不能接听。Companion v0.3.13 (18) 将电话回调与系统状态查询分离，统一权限与响铃序列守卫下的 HTTP/广播/文件接听，并直接回传手机接听结果；Mac v0.4.29 Build46 优先走带回执的独立广播（状态 HTTP 已失效时），保留独立 HTTP 通道。保留 v0.4.28 音频代码，需升级手机伴侣并再次实机验证。

> 09:12 用户实机日志已确认 v0.4.27 的自动接听、OFFHOOK、电话 PCM（1425 帧、RMS 0.11746）和 BlackHole2 输出回调（1423 帧）都正常，但 GPT 仍无回复。v0.4.28 **不更改手机 Companion v0.3.12、ADB 接听、PCM helper**，修复内嵌 WebKit 麦克风 Web Audio 电平图，并增加 BlackHole2 实际输入回环 RMS、WebKit 轨道静音事件、可用时的 WebRTC 实际发声诊断。若通话依然无 GPT 回答，新诊断可明确故障断在驱动回环、网页麦克风或 WebRTC。Mac v0.4.28 Build45；仍需 vivo 实机复验。

> 依据 v0.4.26 Build43 01:09 的真实日志，权限已授权，自动接听卡在先尝试私有文件 NO_ACK 后 HTTP 超时，电话未接通所以 GPT 虚拟麦克风保持静音。v0.4.27 恢复 v0.4.21 实际接通成功的“新建独立 ADB 转发 → POST /call/answer → OFFHOOK → PCM”路径，备用 Shell 广播与文件仅在失败后尝试；不增加只用于拨号的 CALL_PHONE。Android Companion v0.3.12 的前台服务主动核对 TelephonyManager 通话状态，处理 vivo 锁屏迟到的 OFFHOOK 事件，手动接通同一通已跟踪来电后可继续音频 PCM。必须在目标 vivo 真实电话中再次验证自动接听与声音，Mac 编译成功不代表电话自动接通，也不能保证 ChatGPT 官方 Voice 实际识别讲话。

> Mac v0.4.26 Build43 / Android Companion v0.3.11：前一版真实日志显示 APK 已授予 ANSWER_PHONE_CALLS，卡在 ADB 私有接听 NO_ACK、HTTP 超时，以及手动接通后 PCM 根本没有启动；此次让已识别的同一通手动接通电话自动连接 GPT Voice PCM，并增加仅系统/ADB shell 可发送、需会话/响铃序列匹配的 Android 广播接听兜底。安装后仍需真实来电测试验证；不能仅凭 WebKit 已选中 BlackHole 2ch 就判断 GPT 收到语音。

> Mac v0.4.25 Build42 / Companion v0.3.10：手机端明确报告 ANSWER_PHONE_CALLS 权限、私有接听服务状态及处理结果。独立接听回执文件失联时，Mac 可从同一来电的 AtomicFile 状态快照确认结果。若诊断报权限缺失，需在 Android 系统授权；仅凭 NO_ACK 不等于权限被拒绝。

> v0.4.24 Build41 / Companion v0.3.9：已知 ADB_FILE 可读取手机状态、HTTP 不能接听时，优先通过 Android 私有一次性指令触发接听。双方校验当前来电会话与响铃序列，不使用 toybox nc 或按键模拟。升级需要重新安装 Mac 程序并用内置安装功能升级手机 APK；电话音频仍需 vivo 实机验证。

> > 2026-11-23 23:20 实机诊断（Mac v0.4.22）：23:18:33 RINGING；23:18:35 WebKit 录音且确认 BlackHole2；23:18:39 自动请求接听；23:18:41 网页输入为静音；23:18:45 接听 HTTP 超时；23:19:06 直接 IDLE，全程没有 OFFHOOK 和 PCM 电话音频桥接。没有接通时网页静音是预期行为，并不能据此认定 GPT 录音故障。

> v0.4.23 Build40 自动接听优先复用当前 ADB forward；HTTP 转发超时后仅在核对同一 Android 会话、响铃序列和最新 RINGING 状态时，通过受权 ADB run-as 使用手机本地回环接口尝试一次受控接听。认证 token 仅由手机私有文件读取，不经过 Mac 命令行，不模拟可能误挂的耳机键。若手机不支持 toybox nc 等所需能力，则安全失败且保留诊断。电话状态变为 IDLE 时，凡由此次响铃自动启动的 Voice 都会关闭窗口和 WebKit 麦克风，即便 HTTP 回执没收到。原登录状态仍保留，不误关无关手动 ChatGPT 页面。Android APK v0.3.8 未修改；必须实机确认效果。

21:53 诊断（Mac v0.4.21）：自动接听成功，真实通话 PCM 接收 1,431 帧、BlackHole2 设备输出 1,429 帧，电话下行峰值 RMS 0.06734；WebKit 已验证 BlackHole2 音轨，但 GPT 黑洞 16ch 返回的 1,420 帧全部零 RMS。设备选对并不能证明 GPT 网页真正接收到语音。本版给官网 chatgpt.com 的虚拟麦克风采集禁用物理麦克风常用的回声消除、背景噪声抑制和自动增益，并在该网页内仅测量非内容 RMS 阈值，显示输入“有声/持续静音/无法测量”，不保留声音、不访问聊天文本。同时尝试从 BlackHole16 实际活跃通道采集回复，而不是固定读取第 1 个通道。网页实际 Voice 语音识别和响应仍需实机验证。

> 上述通话的安卓 PCM Helper 在 21:52:31 自动断流，原本代码只停止 PCM 并等待 Android 状态从 OFFHOOK 变为 IDLE，网页因防白屏保护一直保留。新版对仅由 SIM AI 自动接听的电话，当原 PCM 端关闭或收到真实 IDLE，先隐藏 Voice 窗口再释放网页音频及麦克风，即使用户先前手动打开过该窗口，也会清理本次自动会话；不盲发结束手机电话指令。其他手动 ChatGPT 会话不受无关电话事件影响。Mac v0.4.22 Build 39；Android Companion v0.3.8 不变，且保持不更改系统默认音频输出。

> 依据 2026-11-23 20:46:56 诊断：电话 20:46:00 RINGING，网页麦克风 20:46:02 激活，独立回复音轨 20:46:10 配置完成，但主页面虚拟麦克风检测一直 WAITING_FOR_CAPTURE；20:46:26 达到 25 秒启动超时并主动调用 releaseForIdle() 将 chatgpt.com 替换为空白 HTML。新版将网页脚本注入官方 chatgpt.com 同源子页面，监听实际 getUserMedia 及 WebRTC outgoing track 的 BlackHole2 设备验证，并以匿名 WKScriptMessageHandler 汇总跨 frame 的有效结果；8 秒内未更新的音轨证据自动失效，仍不把未经验证的物理麦克风送入 GPT。实际兼容性需在用户登录的 ChatGPT 网页上验证。

> 自动接听启动超时、来电状态短暂中断、对方挂机（IDLE）或手动停止自动值守均不再清空已打开的 ChatGPT 页面；仅在显式关闭内嵌模式或退出 App 时释放网页。手动打开的 ChatGPT 窗口也不会因手机状态 IDLE 自动被隐藏。补充匿名的 WebKit 导航与进程终止诊断码，便于区分网站崩溃/页面跳转与程序主动清空。Mac v0.4.21 Build 38；Android Companion v0.3.8 不变，手机无须因本次修复重装。

> 根据 2026-11-23 20:09 诊断：Mac 收到有效来电 PCM（RMS 0.22177，BlackHole2 输出 686 帧），但 GPT 返回 RMS 为 0，WebKit 的 microphoneCaptureState.active 不能证明 GPT 已选择 BlackHole 2ch。本版仅对官方 chatgpt.com 注入网页麦克风设备检测：启动原生 getUserMedia 时清除旧物理设备选择，优先使用 BlackHole2，等待真实音轨验证成功才自动接听。未验证时不会把物理环境麦克风交给 GPT。实际可用性仍受 WebKit 和 ChatGPT 网站限制。
  
> 视频安全模式不再每通电话切换 Mac 系统扬声器。自动值守期间为兼容 WebKit 首次录音，暂时保留 BlackHole2 作为系统默认输入，直至关闭自动值守或退出；因此其他需要使用默认麦克风的软件可能需要手动选择各自麦克风。本程序不会自动改变视频和音乐的系统输出。物理监听耳机临时自动回退不会覆盖用户保存的硬件 UID。

> ADB 方面过滤单次设备空扫描、保留端口转发、延长服务唤醒和 HTTP 退避；安卓后台服务被 vivo 拒绝时，仅对已明确允许监听的 Companion 尝试前台恢复。Android v0.3.8 将匿名电话状态快照刷新间隔由 15 秒缩短到 10 秒。Mac v0.4.20 Build 37；Android v0.3.8 versionCode 13。

> 此版 Mac 程序内置 Android Companion v0.3.7（versionCode 12），构建时校验实际 APK Manifest 版本并写入元数据，UI 不再固定写死 V0.3.5。用户在 Mac 明确点击“一键安装最新版并开启电话权限”后，仅对唯一已授权 ADB 手机安装/覆盖 APK，并请求电话状态读取、接听与挂断两种所需运行时权限；不申请短信权限，不自动卸载或清除手机数据。若系统阻止 ADB 授权，手机端自动合并发起 Android 系统授权，不再要求点击第二个“授权 Mac 控制接听与结束电话”按钮。首次 ADB 授权及 vivo 系统权限仍由系统控制。网页版 ChatGPT Voice 播放受阻的一个可能原因是上一版把 play() 放入了异步 setSinkId Promise，导致用户手势失效；现保留原生同步 play() 调用并报告 NotAllowedError。ChatGPT 官方页面本身的交互限制仍可能要求一次真实点击。Mac v0.4.19 Build 36。

> 默认开启「视频兼容：只隔离 ChatGPT 声音」：不再把整个 Mac 的默认输出切到 BlackHole 16ch；内嵌 ChatGPT 使用 WebKit 在支持时将实际网页音频元素独立路由至 BlackHole 16ch。若网页未提供可路由的音频元素、WebKit 没有列出设备或输出选择被拒绝，则自动接听保持关闭，防止视频声误入运营商通话。仅支持官方 chatgpt.com；不读取网页对话、凭据或媒体数据。每次耳机、蓝牙和视频输出设备改变后，监听目标会用 CoreAudio 设备 UID 恢复，而不是依赖会变化的临时设备编号。保留可手动启用的旧全局切换作兼容测试（视频播放时不要启用）；macOS v0.4.18 Build35，手机 Companion v0.3.6 未变。此方案需要在目标 Mac 上确认 Voice 使用 HTMLMediaElement 并可设置 setSinkId；Web Audio 或非标准播放链路不保证兼容。

> 本版启动时按顺序扫描 ADB、预热已授权手机监听服务、建立状态同步，并在退出时释放本程序的端口转发，降低首次重连错误。针对本应用自动接听的电话，持续检测 Voice 麦克风采集；若超过 4 秒未恢复，通过带 Android 会话 ID 和 OFFHOOK 序列号校验的通道请求结束当前电话。新版 Companion 提供专用挂断接口；旧版 Companion 可尝试经严格状态校验的 ADB 挂断键兼容方式。内嵌 ChatGPT 浏览器和主面板均提供明确的「始终允许官方网站麦克风」开关，关闭即每次询问。系统级权限仍由 macOS 控制；无论是安卓挂断 API 还是键事件，均需 vivo S9e 实机验证。

> 此版本修复 ADB 已识别但 Android 电话监听状态长时间不可用：连接先读私有快照，若过期则在不越过已关闭监听选择和系统权限的情况下尝试恢复 Companion 监听。首次连接不重放历史电话事件。ChatGPT 内嵌窗口新增固定 URL（仅官方 chatgpt.com）、首次用户同意后记住麦克风网站许可、允许取消；GPT 回传开启时默认只在 Mac 监听 AI 一路声音以减少重复监听回音，用户可主动开启双路监听。手机 APK 仍为 v0.3.5。未加开机启动；仍限制每次音频测试 180 秒。涉及通话的性能和回音需要真机确认。


> 本版不添加开机自启动。Mac 应用需由用户打开并保持运行。平时仅保持 ADB 电话状态同步；RINGING 后先验证 HAL PCM 渲染，再加载 ChatGPT 网页并尝试启动 Voice。WebKit 麦克风采集活跃且通话仍在响铃时才请求 Android 自动接听。Voice 超时或音频预检失败则不接听，结束后卸载网页内容但保留登录状态。网页自动启动可能被官方站点拒绝。无法保证 GPT 实际听到语音，仍需实机验证。



**设备目标**：vivo S9e / Android 13 / 中国联通实体 SIM + Apple Silicon Mac / macOS 26.6.2。
**源代码**：https://github.com/popowk/SIM-AI-Assistant

## 已实现并保留

- Android Companion V0.2.0：用户授权的真实来电 RINGING / OFFHOOK / IDLE 监听。
- Mac：ADB 自动检测与手动指定、USB/无线 ADB 授权设备管理、伴侣 APK 安装与覆盖（签名不符时不卸载）。
- Android → Mac：私有通信令牌、本机端口转发、匿名电话状态同步和去重、断线重连。此前 vivo S9e 的真实来电日志已验证此项。
- Mac 本地音频设备检查、麦克风电平、扬声器试听和设备恢复。
- 诊断 ZIP、匿名事件日志、1/7/14 天清理与「清空全部（含今天）」。

## V0.4.14 · 内嵌 ChatGPT Voice 浏览器（实验性自动启动，2026-11-23）

### 已实现

- macOS 原生 **WebKit WKWebView** 独立 ChatGPT 窗口，直接加载 `https://chatgpt.com/`。用户在网页**自行登录**；WebKit 官方 `WKWebsiteDataStore.default()` 负责本机登录会话。SIM AI Assistant 不读取密码、Cookie、Token、聊天内容、语音转写或网页正文，不导出登录信息到日志。
- 「内嵌 ChatGPT Voice」开关和独立窗口；网页登录后，在用户启用的实验性自动启动设置下，软件只在 **HTTPS chatgpt.com 源站**寻找可见、启用且明确标记 Voice 启动的按钮，尝试执行一次点击；不绕过验证码、登录、设备安全策略，不逆向调用未公开的 ChatGPT API。每次自动尝试至少隔 75 秒，避免循环点击和网页卡顿。
- 浏览器麦克风权限遵循 WebKit/macOS 的原生提示，只允许来源为 `https://chatgpt.com` 的页面申请；第三方登录来源无权使用麦克风。**采集状态检测**基于 `WKWebView.microphoneCaptureState == .active`：检测到网页采集后才允许 Mac 自动来电预备，采集停止则停止新来电自动接听，正在回传 GPT 声音的通话也会立即关闭 AI 回传。
- 网页 Voice 启动前，先使用现有 CoreAudio 自动路由确保 macOS 默认输入 BlackHole 2ch、输出 BlackHole 16ch。已经开始的内嵌 Voice 会话在通话空闲时仍维持必要音频路由，停止值守或退出软件后恢复用户原来的设备。实体耳机监听与 Android PCM 桥接流程不变。
- 左侧简洁主界面增加「打开内嵌 ChatGPT 登录与 Voice」，菜单栏同样提供入口。内部日志只记录固定事件代码（启动点击尝试、采集激活/停止、权限提示/拒绝、网页载入失败），不记录网页 URL 参数、账号信息、音频或会话令牌。
- 此版本仅更新 Mac V0.4.14 Build 31；手机 Android Companion V0.3.5 不变，不影响飞书短信转发。

### 限制

- 这只是 **ChatGPT 官方网站的内嵌网页和实验性按钮自动化**，不是 ChatGPT Plus 的授权 API。网页 DOM、语音播放策略、浏览器自动播放限制、macOS 麦克风授权、Voice 会话额度和会话寿命可能导致失败，且无人值守开机后能否自动启动**尚未经过真实 ChatGPT 登录和语音测试**。
- Google OAuth 等第三方登录可能以 `disallowed_useragent` 拒绝 WKWebView。软件可将其跳转在系统浏览器中打开，但外部浏览器登录状态不会自动回写到内嵌浏览器。用户可选用官网支持的其它登录方式，或退回外部 ChatGPT Voice 模式。
- WebKit 的 **麦克风正在采集**只能证明网页请求并获得了麦克风，并不能证明 GPT 正常识别电话对方语音、浏览器使用的是 BlackHole 2ch（如果网站独立选择了物理麦克风）、AI 回复已经进入 BlackHole 16ch，或者通话可以突破现有 180 秒音频 Helper 测试限制。
- 若要真正在开机后保证「不用人工启动网页 Voice、每次都正常对话」，还需采用有公开可编排接口的语音后端或本地 ASR/LLM/TTS。ChatGPT Plus 订阅不能作为第三方应用的编程接口。
- 实际运营商通话使用第三方语音 AI 需当事人知情同意；内嵌网页将声音发送给 ChatGPT 服务，此行为由网站与账号设置管理。勿用于未获授权的通话监控。

### 实机检查

1. 安装新版 Mac 程序，确认 BlackHole 2ch／16ch 和 Android ADB 一切正常。
2. 点击「打开内嵌 ChatGPT 登录与 Voice」，在网页内自行登录。遇到 Google 登录不支持就改用自己受支持的官方登录方法。
3. WebKit 弹出麦克风请求时按照自身意愿确认；如果自动 Voice 点击失败，在网页中手动点一次 Voice 并检查是否看到「网页麦克风正在采集」。此时后台将预备自动值守。
4. 用第二台自有手机拨入测试，确认自动接听、真实电话下行、GPT 回复返回及挂断后的输出状态；仍有现阶段 180 秒音频会话限制。
5. 失去网页麦克风采集时应自动撤销接听预备，不应继续假装 GPT 处于可用状态。保存脱敏日志以便区分网站按钮失效、WebKit 权限和电话 PCM 路由问题。

## V0.4.13 · 修复电话音频大量丢帧（2026-11-23）

用户新提交的 `SIM-AI-Diagnostics-20261123-141842.zip`（V0.4.12 Build 29）确认：
- 06:17:06 已将 macOS 默认麦克风切到 BlackHole 2ch（`INPUT_ACTIVE`）；06:17:33 切到 BlackHole 16ch（`ROUTE_ACTIVE`），自动接听成功，06:17:35 OFFHOOK，06:17:39 ADB PCM 双向会话正常建立。
- 电话下行 `phoneDownlinkPeakRMS=0.27850` 表示 Mac 从 Android 收到非静音的电话音频，`rxFrames=1912`，但本地物理监听丢弃 **1887 帧**，BlackHole 2ch 虚拟麦克风丢弃 **1708 帧**，均不符合实时通话要求。
- GPT 回复 `aiReturnCaptured=1723`、`aiReturnPeakRMS=0.00000`，即检测到输入回调但没有非零 GPT 回传音频；**仍不能单凭日志证明网页实际麦克风选择，或 ChatGPT Voice 是否运行**。

本版技术调整：
- 用 `AVAudioSourceNode` + 有界 16kHz PCM Float 环形缓冲替换每 20ms 调用一次 `AVAudioPlayerNode.scheduleBuffer` 的模式；实时音频引擎主动拉取样本并做设备采样率转换，避免待播放回调没有及时释放导致几乎所有 PCM 帧被拒绝。
- 缓冲上限约 1 秒；短暂设备卡顿时只舍弃最旧的 20ms 帧，不把滞后数据无限累积到后续通话。输出缓冲欠载填静音，不存储原始电话音频。对物理耳机及 BlackHole 2ch 虚拟麦克风均应用这项修复。
- 诊断 ZIP 增加 `physicalRenderedFrames` 和 `virtualMicRenderedFrames`，明确区分**收到电话数据**与**CoreAudio 音频渲染实际运行**；如连接正常但虚拟麦克风渲染 0 帧，记录独立警告 `BLACKHOLE_RENDER_STALLED`。仍保留旧 droppedFrames、音频电平，不在首页显示技术指标。
- Mac V0.4.13 Build 30，Android Companion V0.3.5 不变；自动接听及精简主界面不变。**本版只完成源码与 CI 构建后才视为构建验证；播放改善需要用户 Mac/Android 实机复测**。

验证方法：在官方 ChatGPT Voice 中先确认使用 BlackHole 2ch 输入（某些浏览器按站点锁定麦克风）；准备自动值守后，使用自己的另一部电话进行一通有真人说话的测试，导出诊断 ZIP，比较 `rxFrames`、`physicalRenderedFrames`、`virtualMicRenderedFrames`、`dropped`、`voiceRouteDropped` 和 `aiReturnPeakRMS`。未经同意不得把真实来电内容送到第三方语音服务。当前 180 秒测试限时仍保留。

## V0.4.12 · 修复 GPT 虚拟麦克风与精简主界面（2026-11-23）

依据用户上传的 V0.4.11 Build 28 诊断包 `SIM-AI-Diagnostics-20261123-135319.zip`：
- ADB 电话状态正常，RINGING → 自动接听请求 → OFFHOOK 成功；双向 PCM 16kHz/20ms 已启动。macOS 默认**输出**切换 BlackHole 16ch 成功（`ROUTE_ACTIVE`），电话到 BlackHole 2ch 的发送路由也已启动，但**此前代码未自动管理 macOS 默认麦克风**，无法保证官方 ChatGPT Voice 真正使用 BlackHole 2ch。
- 结束时 GPT 回复 `aiReturnPeakRMS=0.00000`、`aiReturnCaptured=1233`、`aiReturnMonitorDropped=5812`、`aiReturnUplinkUnderflow=4604`、`voiceRouteDropped=4565`。只能证明当时未检测到有效 GPT 回复，不能仅凭这些计数推断 ChatGPT 网页输入设备或电话下行 PCM 内容。
- V0.4.12 Mac Build 29 使用 CoreAudio 新增默认输入自动切换至 **BlackHole 2ch**，同时继续在需要时设置默认播放为 BlackHole 16ch；记录原麦克风 UID，停止值守或退出时恢复。异常退出下次启动检查恢复；若用户手动改输入，则尊重用户选择，不强行夺回。
- 在已准备好 Voice 的值守期间保留 BlackHole 2ch 为默认输入，**避免待机时官方 Voice 误拾取电脑实体麦克风**。通话结束自动恢复播放设备，退出自动值守再恢复原输入。失败时阻止发起空接真实来电，不会改 Android 权限或系统音频服务。
- **核心限制**：更改 macOS 默认麦克风不等于更改浏览器某个站点此前锁定的输入。如果网页或 ChatGPT Voice 已单独选择实体麦克风，仍需要到网站/浏览器内将其首次设为 BlackHole 2ch，必要时重新启动 Voice 会话；软件不能调用 Plus 官方未公开接口更改网站音频设置。若用户对着 Mac 实体麦克风说话，这个自动来电模式不会转给 GPT；输入源预设为**真实电话对方的音频**。
- 另外针对诊断中物理监听和虚拟麦克风的高丢帧，调整 AVAudioPlayerNode 使用渲染完成回调与约 500ms 有界队列，减少设备播放延迟导致的伪队列积压；仍需在 vivo 实机验证。\n- 另外加入不保留电话音频内容的**来电下行 PCM RMS 峰值**统计及 GPT 回声静音分类，只在脱敏日志/诊断 ZIP 中输出；未来可区分“手机下行本身静音”与“网页没有采集麦克风”或“GPT 回传音频静音”，但不能证明网页内部的音频选择。
- 将原来四个阶段的实验控制、逐帧指标和冗长设备列表从默认主界面中移走：主界面只保留**自动值守、首次安装配置、折叠飞书设置、折叠高级维护与诊断**。ADB/飞书/PCM 采集及日志仍在后台运行，诊断 ZIP 可继续导出；没有删除业务能力。
- Android Companion 仍为 V0.3.5，**不需要重新安装手机端**。

### 验证（自己的真实测试号码）

1. 安装 V0.4.12，先在浏览器的 ChatGPT Voice 中确认麦克风为 **BlackHole 2ch**。如果之前选了 Mac 内建麦克风，需要改选一次，重新启动 Voice 会话以应用。
2. 点击 Mac「确认 ChatGPT Voice 已启动」；程序将自动管理 macOS 默认麦克风，电话来电时才管理 BlackHole 16ch 输出。
3. 用第二部自有手机拨入测试普通话语音，观察是否从 RINGING → OFFHOOK → PCM 活跃，GPT 能否回答；不要上传电话录音或验证码。通话超时/挂断后系统播放输出应恢复；停止值守后原实体麦克风应恢复。
4. 如仍听不到，导出脱敏诊断 ZIP。重点检查 `phoneDownlinkPeakRMS` 与 `aiReturnPeakRMS` 是否大于噪声基线，以及 `INPUT_ACTIVE`、`ROUTE_ACTIVE`、`VOICE_ROUTE` 相关错误分类，而不要仅看设备列表。

## V0.4.11 · 在软件中一键获取官方 BlackHole 安装程序（2026-11-23）

- **不需要 Homebrew**：当 Mac 未检测到 BlackHole 16ch 或 2ch 时，SIM AI Assistant「第四阶段 · GPT 回复监听」直接显示「一键安装 BlackHole 16ch」或「安装 BlackHole 2ch」。点击后先提示用户从官方来源下载，确认后应用直接经 HTTPS 访问 Existential Audio 官方下载站，自动下载对应 0.7.1 安装包。
- **安装前安全校验**：应用校验所下载包的固定 SHA-256，与 Homebrew 官方 Cask 记录一致，检查非空合理大小；任何校验失败均不会打开安装程序。仅把用户自行请求的官方安装包保存在个人 App Support 的 OfficialDriverDownloads 目录，不会放入 SIM AI Assistant 的发行 ZIP 或 GitHub release。
- **macOS 授权安装**：校验后使用系统 Installer 打开官方 `.pkg`，用户在 macOS 安装程序中授予必要的管理员权限。不能跳过系统授权、不能静默安装、不能假定已安装就是可用。系统音频服务可能要求重启 Mac。用户安装过程中程序会在后台短时轮询音频设备，识别到 BlackHole 时自动更新状态。
- **为什么没有打进 ZIP**：BlackHole 源码是 GPLv3，但官网明确规定官方编译二进制、名称和相关商标的第三方分发需要另外授权。因此产品集成的是官方下载、固定校验和系统安装器引导，**不是重新分发官方驱动二进制**。许可参考 https://github.com/ExistentialAudio/BlackHole/blob/master/LICENSE。
- **不改手机**：本次仅更新 Mac V0.4.11 Build 28，手机 Companion V0.3.5、电话状态、短信转飞书和现有 GPT 双向音频协议都不变。
## V0.4.10 · BlackHole 16ch 自动输出切换与安全恢复（2026-11-23）

### 改进点（仅 Mac，Android APK 无变化）

- Mac 自动检测唯一的 **BlackHole 16ch** 虚拟音频设备。开始已预备的 GPT 来电时，自动将 **macOS 默认播放输出**切到 BlackHole 16ch，让未单独指定扬声器的 ChatGPT Voice 网页音频进入专用虚拟设备；不再要求每通电话进入系统设置手动切换。
- 继续复用 **BlackHole 2ch 作为电话对方 → GPT 的麦克风**，以及原有 GPT 16ch 回声采集和指定真实耳机/扬声器的监听通道。用户仅需在 ChatGPT 官方 Voice 中预先选择正确麦克风、手动启动会话；软件不能替第三方启动官方 Voice。
- 「自动切换 BlackHole 16ch」默认开启。只在用户已经预备语音会话并触发接听／确认开启 GPT 双向路由时自动改变系统播放输出；不是在安装或开机后无条件劫持所有电脑声音。若物理耳机不存在、BlackHole 缺失或 CoreAudio 拒绝切换，自动接听**不进行**，避免接通后无音频。
- **恢复**：到达电话 IDLE、用户停止 GPT、180 秒 PCM 会话超时／断线、退出 Mac 应用时，程序按此前 CoreAudio 设备 UID 尝试恢复原输出。若程序崩溃，下一次启动检查上次保存的原输出 UID 并尝试恢复。
- 如果用户在软件管理期间通过系统设置自行改了输出，程序**不强行覆盖**这一新选择。若原耳机断开或设备找不到，则显示明确状态，不猜测替代输出设备；可用「立即恢复原声音输出」按钮重新检查。
- Mac 界面会自动选取当前真实默认输出作为监听候选，并显示自动路由状态、异常状态和开关；工具只修改默认播放输出，**不修改系统麦克风、系统提示音输出或操作系统权限**。

### 隐私边界与限制

- 将 macOS 默认声音输出切到 BlackHole 16ch，会把使用默认输出的**其它应用音频**也送进该虚拟设备。需要提前静音其它软件和通知，特别是在向真实电话发送语音之前；不能证明通道只包含 GPT 声音。
- 如果浏览器或 ChatGPT Voice 已单独锁定其它音频输出设备，修改 macOS 默认输出可能无效。需在浏览器/系统中确认当前播放音频是否进入 BlackHole，查看 GPT 回复采集帧数和峰值 RMS。
- 这**不是**真正自动创建 ChatGPT Plus Voice 会话。Plus Voice 无公开第三方会话控制 API；自动值守仍只能复用已经手动开启的官方 Voice。Android Companion V0.3.5 和 180 秒电话 PCM 限制不变。

### 实机验收

1. 确认 Audio MIDI Setup 有唯一 BlackHole 2ch 与 BlackHole 16ch；在 Mac 程序第四阶段选择真实耳机／扬声器；开启「自动切换」开关。
2. 打开 ChatGPT Voice，设 BlackHole 2ch 为麦克风并使 Voice 会话运行，点击 Mac「预备自动值守」。
3. 用自己另一部手机拨入，检查自动切换是否在 RINGING 发生，确认 OFFHOOK 后 GPT 回复采集帧数与非零峰值 RMS，并在已获双方同意的测试通话中确认听感。避免无关程序播放声音。
4. 挂断并检查系统声音输出自动恢复到原来的耳机；重复测试手动停止、音频 180 秒超时、手动切换系统输出以及强制退出后重新打开的恢复行为。
5. 如果缺少 BlackHole 16ch，安装官方虚拟声卡，例如 `brew install blackhole-16ch`，完成系统批准并重启音频应用；不能依靠从实体耳机下拉框里选择 BlackHole。
## V0.4.9 · 自动接听及电话音频状态机（2026-11-23）

目标从每通电话手动点击转为自动响应；本版实现的是**已有语音助手会话就绪后的无人逐通操作**，不声称能自动启动官方 ChatGPT Plus Voice。

- 默认开启「自动接听与连接电话音频」，来电 RINGING 时触发一次原有私有 ADB 接听 API；手机系统再次核验是否确实响铃、是否取得 ANSWER_PHONE_CALLS。只有 OFFHOOK 后才自动启动 PCM。
- 电话 PCM 建立后自动打开 BlackHole 2ch 输入、BlackHole 16ch 回复监听及电话上行；任何阶段失败会关闭相关 GPT 路由并保持 Mac 麦克风静音。来电结束关闭音频并恢复等待下一通。
- **防空接电话**：Mac 启动时不会假定官方 Voice 正在进行。用户需先在官方 ChatGPT Voice 界面启动会话、正确选择音频设备，并在 Mac 一次性点击「确认官方 Voice 已启动，预备自动值守」；此后同一次运行中的后续来电不必逐个点击。软件重启、官方 Voice 会话断开或会话额度用尽时不能保证自动讲话。对方也应知情 AI 参与。
- 依旧是实验性 180 秒上限的电话 PCM，未加入全天候后台自动启动 GPT 或自动挂机。Android APK V0.3.5 不变。实机使用前请务必用自己的测试号码验证接听、路由和异常释放。
- 真正无人工值守的产品方案：使用可编排的语音服务（例如单独计费的 Realtime API，需明确授权费用）或本地语音识别 + 本地大语言模型 + 本地合成器；与 ChatGPT Plus 用户订阅分开，不能通过 OAuth 将 Plus Voice 转成程序接口。详见 [电话 AI 技术方案](docs/AI_PHONE_AGENT_PLAN.md)。

## V0.4.8 · Mac 人工接听 + GPT 双向电话语音联动（2026-11-23）

- Android Companion V0.3.5（versionCode 10）新增可选 `ANSWER_PHONE_CALLS` 系统权限按钮。接听仅由 Mac 用户主动点击；手机端经私有 ADB 令牌认证后**再次校验当前确实为 RINGING**，再向系统请求接听。vivo 可能拒绝，旧版默认拨号应用不变，失败可使用 scrcpy 手动接听。
- Mac V0.4.8 Build 25 新增「人工接听当前来电」、安卓权限指引和 ChatGPT 双向电话引导；电话接通后可经二次知情确认**一键联动** BlackHole 2ch → ChatGPT Voice → BlackHole 16ch → 电话上行，失败自动撤销已开启的路由，另有一键立即停止。
- **本版不自动接听或自动打开官方 ChatGPT Voice**。ChatGPT Plus Voice 需要你在官方界面自行启动，并选择正确输入/输出设备；仍按原先 180 秒限时测试。不将普通通话冒充自动 AI 接线员。完整设计见 [GPT 接电话路线图](docs/AI_PHONE_AGENT_PLAN.md)。
- GitHub 固定签名 Secrets 无法由当前连接直接代写。增加一次性 Mac 本地脚本 `bash Scripts/setup-android-signing.sh`，由仓库管理员用自己的 GitHub CLI 登录将私有证书安全上传；**脚本未在你的 Mac 执行，仓库固定签名尚不能宣称已配置成功**。旧签名不同仍可能需要一次用户确认的迁移。
## V0.4.7 · Mac 通过 ADB 控制 vivo 手机屏幕（2026-11-23）

- Mac 新增 **「手机屏幕操作」**：检测本机 scrcpy（开源 Android 镜像与控制工具）和 ADB，仅对**恰好一台已授权的 Android 手机**打开实时镜像窗口。使用 Mac 鼠标/键盘在手机界面完成安装确认、电话状态/短信权限等系统弹窗操作，无需一直去触摸手机屏幕。
- 下载安装时会尝试自动打开 scrcpy 镜像，并同步运行原有 `adb install -r`。Mac 窗口提供「打开手机屏幕控制」「关闭屏幕控制」「打开手机权限设置」「复制 scrcpy 安装命令」及官方说明。`scrcpy` 不随 APK/Mac 应用捆绑，不会未经同意自动安装第三方软件。
- 本机 Homebrew 安装命令：`brew install scrcpy`。确保 Mac 已安装 ADB；若已配置自定义 ADB 路径，scrcpy 会优先使用相同的 ADB。镜像只传到本机窗口，启动时禁用 scrcpy 音频；不录屏、不保存截图、不读取短信内容、不记录设备序列号。
- 「打开手机权限设置」只通过 Android 系统 Intent 导航到 Companion 的系统应用详情页，**不执行 `pm grant`、`appops`、屏幕自动点击授权**。真正的电话、短信及系统安装授权仍须用户自己确认；普通系统页面可使用 Mac 鼠标点击，但首次 USB 调试信任提示和某些 vivo 特殊安全页面可能要求直接在手机上操作。
- 如果未安装 scrcpy、ADB 未授权、连接多台手机，功能明确失败且不猜测设备；原来的安全 ADB 安装/飞书/PCM 链路不受影响。Mac 使用该工具属于本地第三方程序进程，不连接远程服务，不会自动解锁或绕过手机安全限制。
- 保留 Android Companion V0.3.4（versionCode 9），**这次仅更新 Mac V0.4.7 Build 24**。旧 Android APK 若仍是临时 Debug 签名，签名不匹配不能靠屏幕控制解决，需要按 [安全签名迁移指南](docs/ANDROID_SIGNING_MIGRATION.md) 处理。

### 使用步骤

1. 在 Mac 上先安装 `scrcpy` 并确认 ADB 连通、仅有一台已授权 vivo 手机（第一次 USB 调试授权需在手机上点同意）。
2. 启动新版 Mac 应用，在「Android · ADB / APK 管理」点击「打开手机屏幕控制」，应弹出独立的 vivo 实时画面窗口。
3. 点击「一键安装 / 覆盖并初始化」。出现 vivo 安装确认、应用权限等提示后，在 scrcpy 窗口用鼠标点击。需打开应用设置时点击「打开手机权限设置」，再手动选择授权。
4. 结束操作后点击「关闭屏幕控制」，避免在无需使用时继续暴露手机画面。若 scrcpy 退出，Mac 会在状态区域显示断线或正常关闭。
## V0.4.6 · Android 固定签名升级基础设施（2026-11-23）

- 新 Android Companion V0.3.4（versionCode 9）。GitHub Actions 支持从四项仓库 Secret 安全地读取**同一固定 Android 签名证书**，编译仍为 Debug APK 以保留 ADB `run-as`，保证后续签名连续时可覆盖安装。
- **关键限制：尚未配置 Secret 时仍是 Runner 临时 debug 签名，不保证无损覆盖。** CI 会标记 `EPHEMERAL_DEBUG_SIGNING` 并发出警告；Mac 内置 APK 安装区域也显示固定/临时签名状态。只配置部分 Secret 的构建会安全失败，不会假装完成固定签名。
- 正式启用固定签名需要仓库管理员在 GitHub Settings → Secrets and variables → Actions 设置四项 Secret，详情见 [固定签名与迁移指南](docs/ANDROID_SIGNING_MIGRATION.md)。不要发送 keystore/口令给聊天、公开仓库或诊断日志。
- 已有旧 APK 如由丢失的临时证书签名，新固定证书可能仍需要**最后一次经用户确认的迁移**；绝不自动卸载、清空设置或绕过系统短信/电话权限。完整原有短信/飞书、GPT 音频功能保持不变。
- 为下一阶段新增 [通话本地转写 → 飞书转发设计方案](docs/CALL_TRANSCRIPTION_FEISHU_PLAN.md)：Mac 复用 16kHz/20ms PCM、区分本人/对方/AI，优先本地识别和先人工确认、再独立转发。**当前版本尚未实现转写**。
## V0.4.5 · Android 自动初始化与验证码短信广播诊断（2026-11-23）

- Mac 端安装/覆盖 Android APK 成功后，自动打开手机 Companion；若 Mac 钥匙串已有飞书 Webhook，还会自动下发配置。清空旧 App 数据仍必须用户单独确认，不能偷偷卸载。
- 手机 Companion V0.3.3 首次打开显示一次用途披露。用户点击「开始授权并启动」后依次请求 Android 电话状态权限和 RECEIVE_SMS 权限；**Android 批准电话状态权限后自动启动前台服务**，不需要再点开始监听。
- 新安装默认开启「锁屏运行增强」（会增加耗电）和「自动转发新短信」。已有用户明确关闭的选项继续尊重；手动停止电话状态监听后不会立即自动重启。
- RECEIVE_SMS 属于 Android 系统受限制的权限，不能由应用绕过手机系统或安装来源强制授予；部分 vivo 省电策略也可能干预后台服务。
- 新版手机页面增加不含敏感数据的「收到普通短信广播」累计次数、最近时间，并保持最近发送状态。测试验证码前后比较计数：计数不增长说明 Android 没给 App 发 SMS_RECEIVED；计数增长但飞书没收到，就查看最后一次推送状态。
- Android 官方说明，包含 SMS Retriever 应用哈希的某些验证码只会向对应 App 投递；这类消息并非所有普通 SMS 广播接收器都能收到，无法保证全部验证码自动转发。程序不记录短信正文、发送方、验证码和 Webhook。
- 验收：更新 Mac V0.4.5 Build 22 和手机 Companion V0.3.3 (versionCode 8)，运行一次安装后授权引导，检查电话监听自动开启及两个默认开关，再先发送普通测试短信观察累计计数，最后检查特定验证码是否触发广播。请勿分享真实验证码。

## V0.4.4 · 修复 Mac → 手机飞书配置同步失败（2026-11-23）

来自 `SIM-AI-Diagnostics-20261123-015156.zip` 的实测：Mac V0.4.3 Build 20 两次钥匙串保存成功（01:51:07、01:51:39），两次均记录“ADB 桥接暂不可用”，而且没有有效来电同步状态。**原日志无法证明 ADB 设备到底是否撤销授权**；可以确认原版本不合理地要求电话状态服务/令牌桥接在线。

### 变更

- Mac V0.4.4 Build 21 改为经**唯一已授权 ADB 设备**直接将已保存的 Feishu 配置下发到 Android Companion V0.3.2。无须启动电话状态监听或等待 HTTP 桥接恢复，手机端只要允许 ADB 即可。
- Mac 使用私有 `adb shell -T run-as` + 标准输入传输 JSON，不将飞书地址、签名密钥、设备序列号放进命令参数/诊断日志；手机端通过 0600 权限的私有临时文件与原子重命名接收，导入应用私有设置后删除待处理文件。
- 手机在**打开 Companion 或收到下一条新短信时**自动导入待处理设置。短信发送仍由 Android 独立进行，Mac 可随后退出；不会读取历史短信，也不会把验证码原文写入本地日志。
- Mac 同步前检查已授权设备数量及手机 APK 的 `versionCode >= 7`，拒绝向旧版 Companion 误报成功；失败按固定诊断码区分缺少 ADB、未授权、多设备、旧版 APK、查询/写入超时与 run-as 被拒等情况。
- 注意：ADB 文件写入成功表示**配置已安全下发并等待应用导入**，不证明 RECEIVE_SMS 已经获得运行时授权，也不能证明飞书已收到任何短信。首次使用仍须在手机上主动批准 RECEIVE_SMS，并检查飞书私人群真实测试消息。若 ADB `run-as` 被系统拒绝，请导出新诊断包；旧版 V0.3.1 并不支持这条独立通道。

### 验收

1. 更新 Mac V0.4.4 Build 21 和手机 Companion V0.3.2，勿在签名不一致时盲目卸载（会清除应用本地配置与授权）。
2. 即使手机未运行「电话状态监听」，也可以在 Mac 面板点击「重新同步已保存配置」。确认提示“配置已写入手机私有目录”，而不是之前的“ADB 桥接暂不可用”。
3. 打开手机 Companion，检查自动转发开关与 Webhook 已配置状态，并授予 RECEIVE_SMS 权限；在手机内使用不含验证码的测试通知功能。
4. 退出 Mac 应用，再向自己的测试手机号发送普通短信，验证飞书群收到完整文本。失败时导出 ZIP，日志只会包含固定 `reason` 分类。

## V0.4.3 · 在 Mac 填写并保存飞书 Webhook，同步到手机（2026-11-23）

Mac 诊断中心新增「飞书 Webhook · Mac 设置与手机同步」面板：

- 在桌面粘贴飞书机器人地址、输入可选的签名密钥、切换「自动转发新短信」（默认开启），点击「保存到 Mac 并同步手机」。地址与签名写入**当前 Mac 用户登录钥匙串**，不放入 UserDefaults、JSONL、导出 ZIP 或 ADB shell 命令参数。
- 支持「重新同步已保存配置」：Mac 读取自己钥匙串内容，通过**唯一已授权手机**的 ADB 端口转发（原有手机端 `127.0.0.1:18764`）发送 POST `/sms/config`，带原有私有 64 位 `X-SIMAI-Token`。手机只接受官方飞书 HTTPS Webhook，并将配置保存于 Android App 私有首选项。
- 手机同步成功后，Mac 界面显示「已同步手机」，并报告 Android 是否已获 `RECEIVE_SMS` 权限及转发开关状态。失败只报告错误类别，绝不打印 Webhook/签名；手机拒绝配置不会误报成功。手机端 GET `/sms/status` 只返回开关、权限和是否配置等非敏感布尔值。
- 若 Android 服务未启动/ADB 未授权/手机离线，**Mac 可以先保存**，但不声称已同步；需要打开手机 SIM AI Companion「开始监听电话状态」，确保系统权限和 ADB 连接后重新点击同步。同步时不会向多台 Android 设备随意推送，也不会因断线自动发送配置到不确定的新设备。
- 首次使用需将 Android Companion 更新至 **V0.3.1**（版本码 6）：在手机端用户确认 `RECEIVE_SMS` 权限之后，新短信（包括验证码全文）才可按当前开关直接推送到飞书。未来 Mac 不在线时手机仍可正常运行。Mac 本身**不读取 SMS 全文**。

**升级**：Mac V0.4.3 Build 20 内置 Android Companion V0.3.1，也可独立安装 APK。原有 Android debug 签名可能跨 GitHub Actions 不一致；若覆盖安装失败不会自动卸载或丢数据。原有 V0.4.1 GPT 音频链路不变。

**注意隐私**：验证码被发送到所配置飞书群，群成员可能查看。请使用成员受限的私人群并启用机器人签名；在手机上完成首次授权。构建通过不表示已在用户的 vivo S9e 上实测 Webhook 同步与短信送达。

## V0.4.2 · 短信全文自动发送飞书 Webhook（2026-11-23）

### 新增短信功能（Android Companion V0.3.0）

- vivo S9e 收到**新短信**时，Android Companion 的系统广播接收器读取多段短信，拼接并保留**完整正文（包括验证码）**，连同发送方通过手机网络直接 POST 到指定飞书群机器人。**不需要 Mac 开机、ADB 或电话状态监听运行**。
- 短信推送开关**默认开启**，但必须先在**手机 App** 手动配置有效的 Feishu/Lark 官方 HTTPS Webhook，并在 Android 系统弹窗授予 `RECEIVE_SMS` 权限；否则什么都不会发送。只接收新短信，**不请求 READ_SMS/SEND_SMS，不读取历史收件箱，也不会发送手机短信**。
- App 内支持输入/保存飞书机器人 Webhook、可选的签名密钥（HMAC-SHA256）、测试消息、清除配置、查看上次非敏感的推送结果。实际短信只在内存中处理并发出，不写入私有日志、诊断 ZIP、GitHub 源码或 Mac 的状态桥接。
- 飞书群成员可能查看完整验证码；务必配置由本人控制且仅限授权成员访问的群。推荐在机器人安全设置开启**签名校验**。如果设置了关键词过滤，确保机器人允许消息中的“短信”关键词。Webhook 地址是敏感凭证，不要复制到公开仓库、聊天或诊断日志。
- SMS_RECEIVED 系统广播及一次性异步 HTTPS 发送不保证断网时重试；为避免在磁盘保存验证码，**发送失败不离线缓存原文补发**，失败仅记录原因分类。某些带 App 专属 SMS Retriever 标识的短信不会向一般短信广播接收器分发。

### 升级/验收

1. 从 GitHub 最新版下载 **Mac V0.4.2 Build 19**，内含 **SIM AI Companion V0.3.0 APK**；或者直接下载发布页中的 V0.3.0 Android APK。原来的电话/ChatGPT Voice 路由不变。
2. 手机端点击升级/覆盖 APK（如果不同 CI 构建的 debug 签名不一致，覆盖会失败；不会自动卸载。主动选择清空重装会丢失原 Companion 私有设置、桥接令牌和授权，必须重新配置）。
3. 启动手机 SIM AI Companion，点击“授权接收短信”，在系统权限弹窗同意；确认开关默认勾选。配置飞书自定义机器人 Webhook 和可选签名密钥并保存。
4. 点击“不含验证码的测试消息”，先确认你的飞书私人群收到测试通知。随后使用**本人号码**发送一条普通测试短信，检查飞书是否收到相同的完整短信正文和发送方。不要用真实登录验证码做首轮测试。
5. 让 Mac 退出或关机，在手机仍联网时发送第二条普通测试短信，验证独立于 Mac。最后检查手机页面最近结果；如失败，诊断日志不会附带任何短信内容或 Webhook。
6. 按需关闭默认开启的短信转发开关，或点击“清除飞书 Webhook / 签名”，可立即停止后续新短信向飞书转发。

## V0.4.1 · GPT 回复隔离监听与手动电话回传（2026-11-23）

### 本次诊断事实

- 最新 SIM-AI-Diagnostics-20261123-005010.zip 来自 V0.4.0 Build 17，系统发现 BlackHole，但新会话未出现 V0.4.0 电话音频预览或电话→ChatGPT 路由的启动日志。此前记录的 2,631/2,552 帧来自旧会话，不能冒充本轮验收。
- 截图显示 ChatGPT 生成了文本回复，但并不能单独证明 Voice 语音已从任何设备播放。未听到声音的原因可能是没有打开 Voice、浏览器音量或输出路由到了 BlackHole。

### 两条虚拟设备与两级授权

1. 电话→ChatGPT：继续使用 BlackHole 2ch，用户主动开启电话实时音频和第三阶段的输入路由，ChatGPT Voice 选择 BlackHole 2ch 为麦克风。
2. ChatGPT→Mac 耳机：新增 BlackHole 16ch 输入监听；请将 ChatGPT 语音播放输出指向 BlackHole 16ch。若浏览器不能单独选择输出，可手动将 macOS 默认声音输出设为 BlackHole 16ch。用户须在第四阶段明确选择实体耳机或扬声器，监听默认**不会进入电话**。
3. ChatGPT→电话：本地试听成功、双方明确知情同意后，再单独点击“人工授权：将 GPT 回复发给电话”。启用期间 Mac 麦克风自动关闭，不能和 AI 回复混音；用户可随时点“立即关闭回传”恢复静音。
4. 电话断开后立即释放上述路由，仍受原有 180 秒限制；Android Companion V0.2.2 不变。不自动接听，不操作 ChatGPT 登录和官方 Voice，不使用付费 API，不将声音写入日志或录音。

### 验收步骤

1. 安装 BlackHole 2ch 与 BlackHole 16ch，可使用 BlackHole 官方 Homebrew 方式：brew install blackhole-2ch；brew install blackhole-16ch。安装后在本应用点击“重新自检”。
2. 在第四阶段选择实体耳机/扬声器，最好先选择设备再启动电话音频，以免系统声音输出切换后原有电话监听也进入虚拟设备。
3. 打开官方 ChatGPT Voice；为其麦克风选择 BlackHole 2ch；将其播放输出导向 BlackHole 16ch（必要时手动选择 Mac 系统声音输出 BlackHole 16ch）。
4. 与双方同意的测试对象接通电话，手动开启实时 PCM 和电话下行送入 ChatGPT，然后点“开始在耳机监听 GPT”。让 GPT 说一段测试回复，确认实体耳机能听到，查看 AI 回复采集帧数、峰值 RMS、监听丢帧。帧数增长但 RMS 为 0 可能说明只有静音。
5. 只有确认 Mac 听清 AI 且测试对象知情同意后，才点击“人工授权：将 GPT 回复发给电话”。让对方确认能否听清完整 AI 人声。结束点“立即关闭 AI 电话回传”，并导出匿名 ZIP；查看 aiReturnCaptured、aiReturnPeakRMS、aiReturnMonitorDropped、aiReturnUplinkUnderflow。

### 重要限制

- BlackHole 16ch 如果被用作系统默认输出，会接收其它应用通知和声音，不能保证只有 ChatGPT。务必禁用不相关音频，避免经电话回传泄露；只有在双方知情同意下测试。
- 本版是实验性 CoreAudio 本地路由，不是官方 ChatGPT Plus API 或 OAuth 语音接口。用户的 ChatGPT Voice 使用、处理与保存遵循官方服务规则。
- Mac 虚拟设备输入选择、音频监控和真正的电话上行仍须实机验证。GitHub Actions 构建通过不等于通话中的音质与路由均通过。

## V0.4.0 · ChatGPT Voice 单向电话输入（2026-11-23）

### 新实测与设计边界

- 最新上传的 `SIM-AI-Diagnostics-20261123-003438.zip` 由 **V0.3.4 Build 16** 导出：一个实时 PCM 会话下行 **2,631 帧**、上行 **2,552 帧**、Mac 播放丢帧 **68 帧**、麦克风欠载 **12 帧**、麦克风缓冲溢出 **0 次**、上行迟发帧 **0**，音频握手 **4 次**，最终由 Android 对端关闭音频连接。用户反馈起始略有丢帧、整体可用；日志不足以证明起始丢帧必然由授权引起。
- 本版 **只做电话下行 → 本地 BlackHole 2ch 虚拟麦克风 → 用户手动打开的 ChatGPT Voice**，不提供 ChatGPT 音频回到电话的桥接，不改变运营商电话的自动接听行为；不使用付费 API，不调用或模拟 ChatGPT OAuth。
- ChatGPT 官方 Voice 在支持的界面中使用，用户自行登录、开启会话并选择输入设备。本 App 不读取 ChatGPT 的账号、Cookie、网页或 Voice 会话。
- 双方须明确知情同意电话声音交由 ChatGPT 处理。SIM AI Assistant 保持原有不录音的内存 PCM 传输，但 **ChatGPT 作为独立服务可能处理或保留 Voice 内容，按其产品设置与政策执行**。

### 初次使用

1. 按 BlackHole 官方说明安装 **BlackHole 2ch**（仅这个名称可匹配，防止意外选择扬声器）。在 macOS「音频 MIDI 设置」确认设备出现；Mac 的默认输出继续使用耳机，**不要把默认输出改成 BlackHole**。如果无法路由，先检查设备是否有可用输出通道。
2. 更新 Mac 应用到 V0.4.0 Build 17，Android Companion 保持 V0.2.2 不用重装。点击「重新自检」，第三阶段应显示「已找到 BlackHole 2ch」。
3. 在浏览器打开 [chatgpt.com](https://chatgpt.com/)，手动进入官方 Voice，并在可用的浏览器/站点麦克风设置中选择 **BlackHole 2ch**；系统输出仍保持耳机。
4. 与知情同意的测试对象接通运营商电话，点击「开始实时通话音频」，确认 PCM 帧增长。再点击「将电话声音送入 ChatGPT」，阅读同意弹窗并确认。
5. 此时 ChatGPT Voice 应从 BlackHole 收到电话对方的声音，并可能在 Mac 耳机中回复；**回复不会自动送到电话那端**。结束前先断开 ChatGPT 输入，再停止通话音频；任意断线也会自动停止虚拟麦克风。
6. 导出匿名诊断 ZIP 反馈下行帧、播放丢帧和新增的 `voiceRouteDropped` 数值，另请人工确认 ChatGPT 能否听清对方。不会导出语音内容。

### 隔离说明与验收条件

- V0.4.0 是 **仅接收方向** 的实验阶段，保留原有手动 Mac 麦克风向手机发送声音的功能，并保持默认静音；两个功能独立，不会自动替用户开启。
- ChatGPT Voice 播放设备应保持耳机，避免物理回声。当前版本不会通过程序自动切换 macOS 默认输入/输出，也不会给 ChatGPT 自动点击授权。
- 先验收：BlackHole 是否可枚举、音频输出是否成功、ChatGPT 是否确实听清通话对方、通话停止后路由是否释放、BlackHole 无设备时是否安全拒绝。**GitHub Actions 通过不等于实机语音路由成功。**
- 下一阶段需独立规划 AI 回复 → 电话上行的**第二个隔离音频设备**、人工明确开关、静音/回声保护及对方知情同意，不能把 ChatGPT 的系统播放或 Mac 默认麦克风直接无差别回送到通话。

## V0.3.4 · 实时通话音质优化与详细统计（2026-11-23）

### 诊断依据

上传的 `SIM-AI-Diagnostics-20261123-001312.zip` 来自 Mac V0.3.3 Build 15。日志证实 16:11:58Z ADB_HTTP 来电事件成功同步，16:12:11Z/16:12:51Z HTTP -1001 超时后尝试 ADB_FILE，16:12:31Z 出现 ADB_NOT_READY，16:12:41Z 又自动恢复。**新包没有实时音频帧或麦克风质量统计**，因此不能断言之前反馈的 Mac 麦克风卡顿已经消失。

先前 V0.3.2 的测试记录接收 2,000 帧下行、发送 1,593 帧上行、Mac 下行播放丢帧 107。后一个统计不是麦克风上行丢包率。本版先修复可能造成发送时序累积滞后的实现，并增加区分上下行的指标。

### V0.3.4 技术变更

- Mac 麦克风输入换成固定容量 **12×20 ms（240 ms）PCM16 环形队列**。不再持续对 Swift Array 做 append/removeFirst，输入积压超过上限时仅淘汰最旧的 20 ms，优先保留较新的语音。麦克风关闭后清空队列、继续发送静音而不计欠载。
- AVAudioConverter 复用输出缓冲区，直接将 Float32 转为 PCM16 写入固定队列，避免音频回调反复创建动态数组和 PCM 输出缓冲。
- 上行发送采用 `DispatchTime.now().uptimeNanoseconds` 单调时钟的 20 ms 发送节拍，不再是“写完一帧才 sleep(20ms)”。如果写入阻塞超过一个节拍，跳过过时的时间槽，不进行压缩式突发补发。
- Mac 下行播放队列上限为 18×20 ms（360 ms）；根据实际播放完成回调统计排队情况和溢出的下行播放丢帧。
- 新增 `micUnderflows`（开启麦克风但没有完整采样帧，发送静音）、`micOverflows`（采集积压超过缓冲上限、丢弃旧声音）、`uplinkLateFrames`（上行发送错过的 20ms 发送时隙）及 `micBufferedMs`。只记录计数与毫秒值，不存语音、号码、设备地址、授权秘钥。
- **实时音频期间暂时停止非必要的来电状态轮询**，让有限的 ADB 传输优先发送 PCM。Android Helper 仍自行检查真实电话模式并在通话结束后释放音频；音频结束后 Mac 自动恢复 HTTP/文件备用同步。
- 保留手动启停、麦克风再次确认、通话双方知情同意、最大 180 秒、Android Companion V0.2.2 与原有重连能力。

### 下一轮验收

更新 Mac V0.3.4，手机 APK 无须重新安装。接通双方同意的测试电话后，先听 Mac 下行是否流畅；然后戴耳机开启 Mac 麦克风，连续讲 20–30 秒，由对方评价是否少了卡顿、漏字和明显延迟。检查 UI 的上行欠载、溢出、发送延迟是否持续上升，完成后导出匿名 ZIP。

若 `micUnderflows` 高，优先排查麦克风输入设备、转换和采集调度；若 `uplinkLateFrames` 高，优先排查 ADB/Android AudioTrack 写入背压；若仅下行 `dropped` 高，重点排查 Mac 播放队列。编译通过不等于实机音质已验收。

## V0.3.3 · Mac 自动识别 ADB、来电状态自动恢复（2026-11-23）

### 最新实测

诊断包 `SIM-AI-Diagnostics-20261123-000029.zip` 属于 **Mac V0.3.2 (Build 14)**。ADB 已授权 1 台；23:58:59 左右（Mac 当时当地显示时间）建立实时 PCM 桥接，下行累计 2,000 帧，上行 1,593 帧，Mac 播放丢帧累计 107 帧。用户反馈 Mac 麦克风声音有些卡顿；此统计是**播放端丢帧**而非上行丢包率，需独立排查麦克风重采样与发送时序。来电状态 HTTP -1001 超时后，曾成功走 `ADB_FILE` 快照通道，最后收到 IDLE。

### 新增自动检测与恢复

- **自动识别默认开启**：Mac 启动后查找用户手动指定的 ADB，若先前的文件路径不存在或失效则自动回退到 Homebrew、Android SDK 或系统 PATH 中的可执行 `adb`。不覆盖原手动路径偏好，识别来源会显示在 UI。
- **设备探测**：默认自动执行只读 `adb devices`，判断未授权、离线和已授权状态；连接失效或设备未准备好时约每 12 秒检查一次。手机状态同步健康时把扫描间隔延长至约 45 秒，避免与实时语音争夺 ADB 处理能力；实时语音连接和传输期间不执行额外的自动设备扫描。
- **自动重连**：当原本未授权/离线的手机重新出现为唯一已授权设备时，重置连接退避并立刻尝试连接电话状态桥接；无须点「重新连接」。此前授权过的 Wi-Fi ADB IPv4:port 仍使用已有安全的自动 `adb connect` 恢复，只有单台设备时才自动使用。不调用 `adb kill-server`，不修改其他 ADB 设备。
- **Mac 睡眠唤醒**：监听 `NSWorkspace.didWakeNotification`；来电状态已超过 20 秒没有成功同步时，废弃旧转发并重新识别手机；旧异步连接结果不会污染新会话。
- **来电状态主备继续保留**：主链路为认证后的本机 HTTP；失效时通过已授权 ADB shell `run-as` 读取非敏感匿名状态快照；持续失败退避 2–30 秒，自动重试直到成功。新 UI 显示上一次 ADB 检查时间、识别来源、最近一次状态成功同步时间。
- 两个开关独立：**自动检测 ADB / 手机** 与 **来电状态自动同步** 均默认开启，但用户可自行暂停。
- 调整异步重连后的状态归属：手动换 ADB、Mac 唤醒或重建端口后，旧连接不能把 `bridgeBusy` 错误地提前清空。
- 系统关掉手机无线调试、撤销授权、端口改变或 Companion 被系统强行停止仍需用户恢复对应权限。Mac 不会绕过 Android 锁屏授权，也不会自动接听、录音或运行 GPT。

### 验证步骤

1. 更新 Mac V0.3.3，Android Companion 保持 V0.2.2。正常启动后无需点击「检测 ADB」。
2. 观察「自动识别 ADB 和已授权手机」是否开启，界面是否出现发现来源、已授权设备数与最近检测时间。
3. 连接手机，确认 `IDLE` 状态可以自动同步；拔掉 USB/暂时断开已授权无线 ADB，随后恢复连接，观察自动重新识别与状态恢复。
4. 锁屏两分钟、再唤醒 Mac；检查状态是否通过 HTTP 或文件快照正常恢复；真实测试来电需征得对方同意。
5. 导出匿名诊断包；`自动识别 Android ADB 状态变化` 是设备状态变化事件，不会在每次轮询重复刷入日志。

Mac 麦克风连续语音卡顿将作为后续专门的音频质量问题解决，避免在本次 ADB 重连改动中同时引入额外未验证的重采样修改。

## V0.3.2 · ADB 转发与 Android 音频服务启动竞态修复（2026-11-22）

依据用户上传的 `SIM-AI-Diagnostics-20261122-234743.zip`：Mac V0.3.1 Build 13，ADB 授权正常，23:47:06 和 23:47:29 两次手动启动连续音频分别立即返回 `AUDIO_HANDSHAKE_NO_RESPONSE`，收发帧均为 0；但 23:47:18 下行短测试获取 35,200 样本（RMS 0.02995），23:47:23 上行短测试成功调用 `MANAGER_API_13`。这说明**独立音频接口仍能工作，实时服务启动/握手故障未解决**，但不能从该日志单独断定根因。

本版修复了潜在的启动竞态：ADB 的本地转发端口可能先于 Android `app_process` 监听就绪。Mac 现在在最多 16 秒内重试完整 TCP 连接与握手；如果连接已经被 Android 接受，只是音轨初始化较慢，则保留原连接继续等候，避免误开第二条连接。对于 Android 明确返回的 `ERR`，不会继续盲目重试。启动时若 Helper 进程提前退出，Mac 会仅提取 `SIMAI error` 与 `SIMAI stage` 两类符合严格字符白名单的错误码，不会记录原始 Shell 输出、设备序列号、通话内容或会话令牌。

新增握手重试次数统计与匿名错误分类单元测试。Android Companion 继续使用 **V0.2.2**，不需要卸载或重装；手机短时音频检测代码不变。连续人声双向验证仍需 vivo S9e 实测。

验证：先接通双方同意的测试电话，点击「开始实时通话音频」，观察「音频启动握手尝试」以及是否开始累计下行帧数。若仍失败，导出 ZIP，重点反馈 `reason` 与 `handshakeAttempts`。如能正常播放，先人工确认 Mac 听到对方完整人声，再手动开启 Mac 麦克风，让对方确认听清连续语音。建议佩戴耳机，测试中随时可以立即停止。

## V0.3.1 · 实时音频启动失败诊断和 ADB 推送重试（2026-11-22）

### 基于实际故障包

用户上传的 `SIM-AI-Diagnostics-20261122-233507(1).zip` 明确来自 **Mac V0.3.0 Build 12**。实机仍可以成功进行传统短时测试：上行 `TONE_SENT_UNCONFIRMED`，随后用户人工确认对方听到；下行 `VOICE_DOWNLINK` 读取 35,840 个样本、峰值 0.2485、RMS 0.02446。但**持续实时音频一次因 `AUDIO_HELPER_PUSH` 失败，一次因 `AUDIO_HANDSHAKE_FAILED_OR_NO_CALL` 失败，收发帧均为零**。原日志丢弃了 Android 在握手阶段返回的具体错误，因此不能据此认定是上下行同时打开被系统拒绝。

### V0.3.1 修复内容

- 音频 Helper ADB 推送加入**一次有限重试**（第一次最长 12 秒，第二次最长 20 秒），区分 `AUDIO_HELPER_PUSH_TIMEOUT` 与 `AUDIO_HELPER_PUSH_FAILED`。不重启全局 ADB，不卸载任何手机应用，不跳过设备授权。
- Android AudioStreamServer 在握手期间对音轨格式、`VOICE_DOWNLINK` 创建/启动、`getCallUplinkInjectionAudioTrack` 调用及播放等阶段进行分类。向本机回环连接回复 `ERR INIT_<STAGE>_<CATEGORY>`，不返回 Android 堆栈、通话内容或设备身份。
- Mac 解析**严格白名单**的单行错误码，例如 `ANDROID_NOT_IN_CALL`、`ANDROID_INIT_UPLINK_INVOKE_PERMISSION`、`AUDIO_HANDSHAKE_NO_RESPONSE`，并写入已存在的脱敏 JSONL 诊断记录。原本笼统的握手失败被细分。
- 新增握手错误码解析和敏感文本拒绝的单元测试。
- 双向实时音频仍处于**实验性原型**，并未验证 Mac 连续听清对方的完整人声。原有 Android Companion **V0.2.2** 不变，无需重装手机 APK。

### 再次实测

1. 退出旧 Mac 软件并安装 V0.3.1；保留已授权的 Android Companion 和 ADB。
2. 先接通经双方同意的真实电话，并保持通话不中断。
3. 点击「开始实时通话音频」，等待 Mac 显示「实时播放电话下行」或明确的 Android 握手错误。
4. 只有 Mac 已经能清晰听到对方讲话后，再佩戴耳机并手动开启麦克风，让对方确认听到完整人声。
5. 失败时导出诊断 ZIP。特别关注 `reason` 字段，如 `ANDROID_INIT_UPLINK_INVOKE_PERMISSION`、`ANDROID_NOT_IN_CALL`、`AUDIO_HANDSHAKE_NO_RESPONSE`、`AUDIO_HELPER_PUSH_TIMEOUT`。

即使编译通过，也不能承诺 vivo S9e 同时采集/注入真实通话声音已经成功。下一步依据具体阶段调整声音路由或协议，而非重复盲目安装 Shizuku。

## V0.3.0 · Android 13 运营商通话双向实时 PCM 原型（2026-11-22）

### 实际依据

用户已经明确确认：**运营商电话对方能够听到 Mac 发出的测试音**。既有音频 Helper 通过 Android `VOICE_DOWNLINK` 读到非零 PCM；但之前没有将对方真实语音持续播放到 Mac。V0.3.0 在此基础上引入手动启停的实时双向音频原型，**首次连续真实通话音质、麦克风双方听辨和稳定性仍需 vivo S9e 实机测试**。

### 架构及授权

- Mac 在用户明确确认对方同意后，推送内置 `SIMAI-Audio-Probe.jar`，使用已有 ADB shell 权限临时启动 `AudioStreamServer`（不需要 Root 或额外硬件）。
- Android Helper 仅监听 `127.0.0.1:18765` 并检查 64 字符随机会话令牌；Mac 使用**独立** `adb forward tcp:0 tcp:18765` 建立 TCP。电话状态的 HTTP 桥接/文件快照与其互不依赖。
- Android 通话模式检查通过后，以 `AudioRecord(VOICE_DOWNLINK)` 将下行 16 kHz/mono/PCM16 实时传给 Mac，通过 CoreAudio/AVAudioPlayerNode 输出。
- Mac 默认发送静音帧，只有用户再次明确同意并授权麦克风后，才使用 `AVAudioEngine` 与 `AVAudioConverter` 采集/重采样到 16 kHz，再通过专用 `AudioManager.getCallUplinkInjectionAudioTrack` 返回给运营商通话。
- 每帧 20ms（640字节单向），约 256 kbit/s 总裸音频速率（上/下各约 256 kbit/s），具体无线封装另计。没有保存语音、进行网络广播或向 AI API 发送通话内容。
- 麦克风默认静音，Mac 端允许随时静音/停止；连续测试最长 180 秒，断线或通话模式结束自动关闭。保留 20ms 帧计数及 Mac 端丢帧统计，日志不包含号码、语音、令牌、真实设备序列号。
- 为避免回声，建议佩戴耳机而不是让 Mac 扬声器直接靠近麦克风。手机原生拨号和接听功能不变。

### 实机验证

1. 更新 **Mac V0.3.0** 即可；Android Companion 继续使用 **V0.2.2**，手机 APK 不必覆盖重装。
2. 确保 ADB 已授权并能完成上一阶段音频接口检测。与另一位**知情同意**的真实测试对方接通联通电话。
3. 点击「开始实时通话音频」，在确认弹窗同意后，尝试听对方讲话。此时 Mac 麦克风为静音，电话上行送静音帧。
4. 如果 Mac 可清晰听到对方讲话，戴好耳机，再点击「开启 Mac 麦克风」并确认。请对方复述是否听到你从 Mac 麦克风说出的完整一句话（不是仅短提示音）。
5. 可随时静音或停止；约 3 分钟自动结束。如果出现回声、挂断后无声、帧增长异常或延迟大，立即停止并导出诊断 ZIP。
6. 观察「下行接收帧」「上行发送帧」「Mac 播放丢帧」随时间的变化。接收帧数字增长只证明传输有效，能否听清真实对方说话仍需人工确认。

### 限制与后续

- 原型在**用户已建立真实通话**后手动开启，无自动接听，不连接 GPT，不使用 Shizuku，不使用蓝牙 HFP。
- 无线 ADB 可能被手机厂商系统省电策略影响；断线后本次语音会话结束，不在未授权状态下重开通话音频。
- Android 使用的系统级音频接口可能在某些电话模式不允许同时采集和注入。必须以 vivo S9e 的持续双向实测为准。
- 下阶段在确认双向真实语音质量后再实现 Opus、自动恢复、Shizuku UserService 和 AI 辅助。ChatGPT Plus 订阅不等于程序化 API 额度。

## V0.2.4 · 匿名电话状态快照备用（2026-11-22）

### 实机依据

诊断 ZIP `SIM-AI-Diagnostics-20261122-230139.zip` 来自 Mac V0.2.3 Build 10。在多次 `NSURLErrorDomain -1001` 超时期间，ADB 已授权、Shell 正常且端口映射仍在，分类为 `PHONE_SERVICE_TIMEOUT`；独立 Android 音频 Helper 仍可工作。下行有 35,200 个非零 PCM 样本、RMS 0.08331；上行经 `MANAGER_API_13` 写入测试音，用户两次点击「对方确认听到」。这不能替代连续音频流与下行语音听辨的真实测试。

- **主链路**：保留 ADB 端口转发 + 带授权 token 的 Android 本地 HTTP 电话状态接口。
- **备用链路**：Android Companion V0.2.2 将匿名事件、会话、状态和存活时间通过 `AtomicFile` 保存到私有 `files/bridge-snapshot.json`。状态变化时立即写入，服务存活时每 15 秒刷新。
- Mac 在 HTTP 超时时通过先前已授权的 ADB `run-as` 读取状态快照，**不需要 HTTP 或端口映射，但仍需要有效 ADB 授权**。快照上限 32 KiB，过期超过 90 秒或服务停止时拒绝。
- HTTP 和文件通道共用原来 PhoneBridgeCursor 去重，文件正常时每 20 秒尝试恢复 HTTP；备用可用时避免反复重建端口。
- 后续 Shizuku Wi-Fi 传输可直接复用该匿名状态协议，不再另起状态模型。

### 安装与验证

1. 安装 Mac V0.2.4，再通过「一键安装/覆盖」升级手机 Companion V0.2.2（不同 CI debug 签名可能不允许覆盖，**不会自动卸载**）。
2. 手机上重新确认监听服务正在运行，按需开启后台权限与锁屏运行增强。
3. 锁屏两分钟，并用同意参与测试的另一手机拨入。观察 Mac 是否显示「ADB 私有状态快照（HTTP 备用）」以及来电状态变化。
4. 导出 ZIP，查看 `source` 是 `ADB_HTTP` 或 `ADB_FILE`，确认切换时没有重复来电事件。

本版不录音、不传输电话音频、不启动 GPT、不自动接听。如果锁屏时连 ADB Shell 都不能执行，备用文件读取也会失败，那时需要独立 Wi-Fi 状态链路，而非无限重新连接。

## V0.2.3 · vivo Android 13 锁屏状态同步适配（2026-11-22）

### 诊断事实与限制

上传的 ZIP `SIM-AI-Diagnostics-20261122-223352(1).zip` 实际来自 Mac **V0.2.1**，并非刚发布的 V0.2.2。它在 22:31:46、22:32:54 两次从 Android 读取音频能力成功；在状态 HTTP 桥接中出现 -1001 超时，到 22:33:45 才补收 RINGING → OFFHOOK → IDLE。**日志没有保存每次锁屏/解锁状态，因此无法断言 ADB 授权被撤销**。有可能是 adbd/TCP 在锁屏受限，也有可能是 Companion HTTP 服务/CPU 进入休眠。

Mac V0.2.3 将四个状态分开：**已授权 ADB 设备**、**手机 shell 可执行命令**、**ADB 端口转发是否存在**、**HTTP 电话状态服务是否正常**。点击「诊断连接层」可在手机已锁屏时运行；HTTP 第一次超时会自动执行匿名分层诊断，并把分类错误写进诊断 ZIP。绝不记录原始 ADB 输出、手机地址、序列号或授权 token。原有断线自动重连继续保留。

### Android Companion V0.2.1（手机侧可选更新）

- 将只读 127.0.0.1:18764 状态接口改为**有界并发请求处理**，避免一个请求挂起时后续请求全部排队；仍须原有 64 位随机 token 才能读取事件。
- 用户主动启动的前台监听服务改为 `START_STICKY`，以便 Android 允许时重建；不会规避系统强制停止。
- 新增明确选择的「锁屏运行增强（增加耗电）」：只在电话监听前台服务运行时持有有限时长的 PARTIAL_WAKE_LOCK，并定期续期；停止服务或取消勾选后释放。
- 新增「打开本应用系统设置」入口，便于用户自行允许 vivo 后台运行、自启动、取消省电限制等。
- 无Root、不控制电话、不采集双方通话音频；该电源锁**不能在 Doze 已禁止网络或系统关闭无线 ADB 时强制保活**。

**安装注意：** 手机 V0.2.0 旧 APK 可能与 CI 新 APK V0.2.1 的 debug 签名不一致，因此普通 `adb install -r` 可能被拒绝。新 Mac App 不会自动卸载原应用。若使用专门的「清空旧伴侣数据并重装」按钮，将删除旧 Companion 数据及权限，请确认后再操作；原联通 SIM、其他应用及通话记录不受影响。更新手机后必须重新授予电话状态权限、重新开启监听和选择锁屏运行增强。

### 实机验收

1. 先更新 Mac V0.2.3，手机原 APK **可以不动**；在锁屏时点击「诊断连接层」查看四项结果。
2. 若 ADB/Shell 均在线，但 HTTP 状态服务无响应，可选择更新手机 V0.2.1，并在手机端打开「锁屏运行增强」、允许后台运行。
3. 保持 Mac 状态自动同步开关开启，手机锁屏约 2 分钟，然后拨打一次知情同意的真实测试电话。
4. 如果仍超时，导出诊断 ZIP，检查 `ADB_SHELL_TIMEOUT`、`PHONE_SERVICE_TIMEOUT`、`ADB_FORWARD_MISSING` 等分类。不要通过关闭手机锁屏密码来绕过安全机制。

## V0.2.2 通话按钮及自动恢复（2026-11-22）

**原因来自用户 vivo S9e 诊断包（22:33:52）**：Mac 多次 HTTP -1001 超时，直到电话结束才补收到完整的 RINGING → OFFHOOK → IDLE 事件。由于 V0.2.1 界面和 Model 均要求 Mac 当前显示 OFFHOOK，导致用户在已接通的真实通话中无法点击下行、上行测试。

- **解除不可靠的 Mac 状态门禁**。用户在确认弹窗中明确同意后可运行下行/上行测试。Android Helper 在执行实际采集/注入前仍会通过 AudioManager.getMode() 检查真实通话音频模式；非通话状态返回 PHONE_NOT_IN_CALL_AUDIO_MODE，不进行录音/发声。
- **Mac 端状态同步与诊断独立**：Mac 状态显示 IDLE、未连接或事件迟到，均不会锁死测试按钮。
- **自动状态桥接恢复**：默认启用，每 2 秒检查是否需要重试。单次 URL 请求最长 6 秒（避免较忙手机造成误报），失败按 2 / 4 / 8 / 16 / 30 秒退避；断连时仅重连当前进程使用的转发端口，不重启全局 ADB 服务。恢复后保留手机会话事件游标避免重复统计。
- **无线 ADB 传输恢复**：自动记住已经授权且识别到的 IPv4:port 地址（仅本机 UserDefaults，不写入诊断包），设备临时离线时可自动尝试 adb connect。新地址、手机重启导致无线调试关闭、权限撤销或配对失效，仍需用户重新开启/授权。
- **防止旧任务污染新连接**：用户关闭同步、手动重连或更换 ADB 路径后，旧异步响应不会覆盖新状态。
- Mac 显示最近一次成功同步时间；新增自动退避和地址校验单元测试。

**手机 Companion 仍为 V0.2.0，Android 音频 Helper 与 V0.2.1 逻辑相同。无需覆盖或重装手机 App。**

## V0.2.1 真实设备诊断修复（2026-11-22）

vivo S9e / Android 13 / 联通真实电话测试已得到：
- 电话状态 \`OFFHOOK → IDLE\` 被 Mac 接收。
- \`pstnInterceptable=true\`，表示系统报告 PSTN 可重定向。
- \`VOICE_DOWNLINK\` 返回 34,560 样本，峰值 0.2435，RMS 0.02590，\`NONZERO_PCM\`；证明获得了非零采样，但**未在 Mac 播放或验证它是否就是通话对方的声音**。
- 旧上行测试返回 \`API_MISSING\`，无法判断是 \`setSystemUsage\` 还是 \`setForCallRedirection\` 缺失。

本版上行测试优先调用 **Android 13 的 \`AudioManager.getCallUplinkInjectionAudioTrack(AudioFormat)\`**（AOSP Android 13 系统 API；须系统允许 \`CALL_AUDIO_INTERCEPTION\`），只有该方法在手机系统上确实不存在时才尝试旧的属性标记方案。不尝试规避 Android 权限政策。

增加 \`uplinkManagerApi\`、\`legacyCallRedirectApi\`、\`route\`、\`stage\` 的匿名诊断信息，区分系统接口缺失、方法调用、Track 创建、播放及 PCM 写入等阶段。**成功写入并不证明对方听到了测试音，仍需通话对方的人工确认**。

同时诊断发现约 22 次连续 ADB 端口转发重建，HTTP 层错误包括 \`NSURLErrorDomain -1001\`（超时）和 \`-1005\`（连接中断）。本版对重复故障实施指数退避（4–60 秒）、减少重复日志、优先复用连接一次，并记录恢复情况。这缓解刷日志与重连压力，**不代表已确定底层断线原因或保证始终在线**。

本次没有修改 Android Companion APK（仍为 V0.2.0）。用户只需更换 Mac V0.2.1；诊断 Helper 已自动内置并会在点击测试时通过 ADB 运行。

## V0.2.0：第一阶段音频兼容性验证

该版本新增 **Android 13+ 电话音频短时检测助手**（`SIMAI-Audio-Probe.jar`）：
Mac 在用户主动点按钮时，将独立 Java/Dex Helper 放进手机 `/data/local/tmp`，通过 ADB 的 shell 身份调用 Android `app_process`，采用与 PhoneBridge 相似的技术路径，而不使用 PhoneBridge 的蓝牙 HFP 控制。

**无需** Root / Shizuku / 数据线（已配对无线 ADB 时）/ 外置蓝牙网关。现阶段仅验证 Android 13 的底层音频能力，并未构建实时音频流。

### 实机测试步骤（建议使用已知同意参加测试的另一位通话者）

1. 退出旧 Mac 版，启动 **V0.2.0**。保留手机端已成功安装的 **SIM AI Companion V0.2.0**，**无须重新覆盖 APK**。
2. 保持 vivo S9e 上 Companion 的电话监听服务运行。使用 USB ADB 或事先授权的无线 ADB，确保 Mac 显示唯一已授权手机、能够实时看到 `IDLE`。
3. 点击「1 · 检测音频接口」。只读取 Android SDK、shell UID、AudioManager 模式以及可查询的 `telephonyOutput/pstnInterceptable`。`unknown` 表示系统私有接口不可查询，不能当作已通过或失败。
4. 与知情同意的另一方建立一通真实电话，等待 Mac 状态变为 `OFFHOOK`。
5. 对方持续讲话时，单击「2 · 测试通话下行」，确认弹窗后约 2.2 秒读取 `VOICE_DOWNLINK` 的 PCM **电平统计**（峰值、RMS 和样本数）。**不输出、不保存音频样本**。非零统计不能单独证明声音来自通话对方。
6. 提前告诉对方将会听到短促提示音，单击「3 · 测试通话上行音」并确认。Android 尝试通过 `AudioTrack / USAGE_CALL_ASSISTANT / setForCallRedirection` 输出约 1 秒的低幅度测试音。**即使程序写入成功，也必须问通话对方是否实际听到**。只有得到确认才点击「对方已确认听到测试音」。
7. 通话结束导出诊断 ZIP 反馈。日志只含阶段、结果、错误码、少量数值，不包含原始 PCM、电话号码或设备序列号。

### 判定标准

| 项目 | 解释 |
|---|---|
| Helper 启动失败 | ADB、构建或 OEM Shell 运行环境问题；后续定位 |
| `pstnInterceptable=true` | 系统声称允许 PSTN 重定向；仍不等于可用 |
| 下行报告有样本且非零 RMS | 有 PCM 信号，尚需真实音频听辨验证 |
| 上行报告 `TONE_SENT_UNCONFIRMED` | 音频写入接口成功；**不等于对方听到** |
| 对方人工确认听见 | 上行注入得到初步实机证据 |
| 两方向均失败 | 可能是系统/音频 HAL 限制，两套 ADB/Shizuku 方案都可能受影响 |

如果手机因 OEM 策略拒绝 `VOICE_DOWNLINK` 或上行重定向，程序只报告错误，不尝试绕过系统的安全权限，也不会修改手机通话设置。

## 清理旧代码

本版从运行入口删除已失去实际用途的：蓝牙/HFP 设备观察、60 秒模拟来电观察、模拟来电状态机、模拟故障按钮、本机回环、手动 Voice 状态开关。清理过时的文案和初始化逻辑。保留历史日志解码所需的旧诊断模块枚举以兼容既有 ZIP/JSONL。未改动 Android Companion 的已验证来电状态监听与通信协议。

## 第二阶段（尚未实施）

- 在实机第一阶段通过后，扩展 ADB Helper 为可控的**实时双向音频流**（PCM/Opus、流量加密、超时、显式授权）。
- 接入 Shizuku UserService 作为第二种**启动与 Wi-Fi 传输方式**；与 ADB 共用音频引擎。
- 之后再接本地 ASR/TTS、GPT、人工辅助和自动接听。**不保证两个方案永远在线**；两者都依赖 Android shell 及 OEM 音频政策。

## 构建与版权

GitHub Actions 使用 Android SDK 35 + JDK 17 / d8 构建音频诊断 Helper、Gradle 编译原有测试 APK、Swift 编译 Mac 应用并将两者嵌入 .app。用户亦可执行 `bash Scripts/build-audio-probe.sh` 与 `bash Scripts/build-macos.sh`（后者需设 `ANDROID_AUDIO_PROBE_JAR_PATH`）。

测试版 Mac 应用为临时签名而非 Apple Developer ID 公证，Android APK 为 CI debug 签名；跨运行覆盖可能签名不一致。**不要为了安装这次 Mac 更新而卸载已正常工作的手机 APK。**

音频底层架构参考 [PhoneBridge](https://github.com/AbinMadathil07/PhoneBridge) 与 [scrcpy](https://github.com/Genymobile/scrcpy)，见 THIRD_PARTY_NOTICES.md。请仅在具有通话双方知情同意的情况下使用真实电话测试。
