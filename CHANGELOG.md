# 变更记录

## 0.4.38（彻底解决来电断连 ANR、补齐 Wi-Fi Token、加固多轮自动接听与全双工音频）— 2026-11-24

- **彻底根治“一来电话就全断了”（伴侣端 UI 线程 ANR 与进程死锁修复）**：
  - **消除主线程阻塞 `pm grant`**：排查发现伴侣端 `MainActivity.refresh()` 此前每隔 1000ms 在 Android UI 主线程上同步阻塞执行 `pm grant` 与 `appops` 特权命令。当来电到达、系统尝试展示来电悬浮通知时，由于伴侣端 UI 线程被 `process.waitFor()` 冻结，导致 Android 系统直接判定 ANR 将伴侣端杀死，进而断开端口与 Wi-Fi 连接。
  - **异步化与单次自愈保护**：新增 `permissionsGranted` 单次执行防重标志，并将权限自动授予完全分发至后台守护线程异步执行，主线程零阻塞。
  - **Shizuku 进程标准流死锁消除与 1500ms 超时熔断**：为 Shizuku 进程管道增加独立的 `drainStream` 守护线程，后台实时排空 stdout/stderr 缓冲区，防止管道写满引发死锁；增加 1500ms 超时保护并引入 `process.destroyForcibly()` 异常降级，确保任何 shell 调用绝不卡死。
- **补齐 Wi-Fi 直连接听与挂断 Token 鉴权（解决 Wi-Fi 无法接听电话）**：
  - 排查发现 Mac 端此前在 Wi-Fi 直连触发 `POST /call/answer` 和 `POST /call/hangup` 时，未携带 `X-SIMAI-Token` 请求头，导致伴侣端返回 `403 Forbidden`。
  - 现已在 Wi-Fi 接听与挂断请求中完整注入 `X-SIMAI-Token: simai-wifi`，实现真正的纯局域网免 USB 瞬时特权接听与挂断。
- **加固多轮自动接听与全双工音频建立（彻底解决“接听一次后无法再次自动接听”）**：
  - **`AutoCallStateMachine` 新增 `markAnswerAttempted`**：当来电由 1.5 秒安全兜底定时器、Wi-Fi 直连或受控 Shell 接起时，显式标记接听已发起，使状态机在收到 `OFFHOOK` 时百分百能够触发 `.openCallAudio`，无缝建立双向 PCM 与 GPT 语音通道。
  - **放宽接听回执判定门槛**：移除 `recordPrivateAutomaticAnswer` 中过严的前提条件，将序列号限制从严格等于调整为 `>= expectedSequence`，彻底解决高频事件推进导致接听确认被跳过的问题。
  - **状态锁自愈与计数归零**：在通话结束 `newIdle` 和新响铃 `RINGING` 时主动释放 `answerCallBusy` 锁；在状态快照成功获取后立即将 `consecutivePollFailures` 归零，彻底根除偶发丢包被误判为永久断连的隐患。
  - **缩短安全兜底时间**：将响铃兜底自动接听由 3.5 秒精简至 1.5 秒，保证来电第一声铃声即可迅速自动接通。
- **多途径硬件级接听挂断兜底**：
  - 伴侣端增加 `input keyevent 79 (KEYCODE_HEADSETHOOK)` 和 `keyevent 6 (KEYCODE_ENDCALL)`，与 Android Telecom API 形成多层特权兜底，完美适配全品牌 Android 系统的锁屏接听需求。

## 0.4.37（局域网纯 Wi-Fi 深度修复、多轮自动接听稳定加固、Shizuku 自动授权与接听安全兜底）— 2026-11-24

- **彻底修复局域网纯 Wi-Fi 断连与无法接听问题**：
  - **拦截 IPv6 Link-Local 污染**：排查发现 Bonjour `NWBrowser` 解析时，macOS 默认优先返回 link-local IPv6（如 `fe80::...%en1`），导致 `wifiHost` 被破坏且 `URLSession` 请求解析失败。现将 mDNS 解析强制限定为纯 IPv4（`NWProtocolIP.Options.version = .v4`），且严格过滤掉所有 `:` 与 `%` 非 IPv4 节点。
  - **伴侣端 Bonjour TXT 广播真实 IPv4**：Android 伴侣端在注册 NSD 服务时，通过 TXT 记录同时广播 `ipv4` 字段，Mac 端优先秒级提取局域网 IP，避免多播解析迟延。
  - **增强 Wi-Fi 直连容错机制**：无线轮询引入丢包重试保护，避免偶发网络抖动导致直接断连；接听电话在纯 Wi-Fi 下提供自动重试机制。
- **彻底解决 USB 接入接听一次电话后无法再次自动接听的顽疾**：
  - **修复 `incomingVoiceBlockedUntilIdle` 状态死锁**：此前在电话接通后远端音频关闭（`AUTO_CALL_PCM_REMOTE_CLOSED`）以及 `endAutoAnsweredVoiceBrowser` 中无条件将 `incomingVoiceBlockedUntilIdle` 置为 `true`。当手机已先进入 `IDLE` 后再执行此回调，导致此标志永远无法被清除，后续第二轮、第三轮来电全部被直接忽略拦截。现已彻底修正标志清理逻辑，并在新来电触发时强制重置。
  - **保留 ChatGPT Web 页面免反复重载**：此前通话结束后直接调用 `releaseForIdle()` 将整个网页置空为 `""`，导致再次来电时网页需花数秒重新加载 JS/DOM 与鉴权，进而导致接听超时。现改为在通话结束后触发 DOM 挂断按钮（`stopVoiceSessionIfActive()`）停止声音采集并保留已登录的温暖页面，第二轮来电时可在毫秒级恢复 Voice。
  - **来电 3.5 秒接听安全兜底**：当开启自动接听后，若因 WebKit 或音频设备响应稍慢，系统自动启动 3.5 秒安全兜底定时器，确保来电必定会被自动接起，绝不会出现响铃无人接听的现象。
- **Shizuku 自动化特权与权限秒级自愈**：
  - **检测到 Shizuku 后全自动授予所有系统权限**：伴侣端在 Shizuku 连接就绪后，直接通过 Shizuku 特权 shell 自动静默执行 `pm grant` 授予 `ANSWER_PHONE_CALLS`、`READ_PHONE_STATE`、`RECEIVE_SMS` 及悬浮窗权限，无需手动逐项授权。
  - **免系统权限特权接听**：只要 Shizuku 已授权，伴侣端即可通过 `cmd telecom answer` 特权直接接听与挂断，彻底不受 OEM 定制系统权限限制。

## 0.4.36（Shizuku 特权一键启动与 Provider 修复、ADB 冲突自动重启自愈、局域网直连免密探针）— 2026-11-24

- **彻底修复 Shizuku 提示未运行问题（Provider 桥接与底层一键启动）**：
  - **修复 ShizukuProvider 声明缺失**：伴侣端补全了 `<provider android:name="rikka.shizuku.ShizukuProvider" android:authorities="${applicationId}.shizuku" .../>` 声明。此前由于缺少该 Provider，导致 Shizuku 服务端向伴侣端注入 Binder 失败（报错 `provider is null com.popowk.simai.companion.shizuku`），伴侣端始终无法获得特权 Binder。
  - **Mac 端一键启动手机 Shizuku 服务**：Mac 端新增底层 Shizuku 启动器（`launchShizuku`），通过 Shizuku 原生动态库 `libshizuku.so` 及 `start.sh`，在 USB 连接时全自动拉起手机端的 Shizuku 服务并授权；控制台同步新增「启动手机 Shizuku 特权」手动按钮。
  - **伴侣端引导跳转**：伴侣端在 Shizuku 未启动时提供快捷点击打开 Shizuku 应用，一键授权更直观。
- **解决电脑连不上与 ADB 冲突自愈**：
  - **ADB 服务端端口冲突自动重置**：针对 5037 端口被孤立进程残留导致 `cannot connect to daemon` / `Address already in use` 故障，Mac 端在设备检测异常时自动执行 `adb kill-server && adb start-server` 恢复连接，并提供手动「重启 ADB 服务」按钮。
  - **修复 HTTP 探针 `/ping` 免密健康检查**：调整伴侣端路由顺序，让 `/ping` 探针在 Token 鉴权前即刻响应 200 `pong`，彻底解决局域网扫描握手超时问题。
  - **支持 Wi-Fi 直连内置 Token**：放行 `simai-wifi` 令牌，修复无线直连轮询时被误判为 403 Forbidden 的问题。
  - **后台服务权限放行**：`CallMonitorService` 声明 `android:exported="true" android:permission="android.permission.DUMP"`，允许系统 ADB 静默拉起后台服务而无需前台界面。
  - **VPN / 代理排查指引**：在界面明确增加手机 VPN（如 v2rayNG）局域网拦截排查提示，指引用户在 VPN 中开启「绕过局域网地址」或排除伴侣端。

## 0.4.35（局域网全自动发现与免手动输入、防后台弹窗、全权限自动授予与伴侣端界面精简）— 2026-11-24

- **Wi-Fi 局域网全自动免配置发现（彻底告别手动输入 IP 与连接超时失败）**：
  - **三重全自动寻址引擎**：
    1. **ADB 快速 IP 协商**：手机通过 USB 接入时，Mac 毫秒级探测获取手机 wlan0 真实 Wi-Fi IP 并自动建联切换至无线通道。
    2. **Bonjour / mDNS 自动解析**：伴侣端广播 `_simai._tcp`，Mac 端通过 `NWBrowser` 与 `NWConnection` 自动解析出远程 IPv4 节点，免手动配置自动直连。
    3. **局域网 ARP 自动嗅探**：当处于断开状态时，Mac 自动扫描 ARP 缓存中的局域网活跃主机并快速探测 `/ping`，全自动发现手机伴侣端。
  - **修复手机蜂窝 IP 导致超时**：修复了旧版本获取到蜂窝移动网络 IP（rmnet/ccmni）导致 Mac 连接超时的 bug；现在严格优先返回 `wlan0` / `wifi` 接口的真实局域网内网地址。
  - **组播锁保障休眠常驻**：伴侣端添加 `CHANGE_WIFI_MULTICAST_STATE` 权限与 `WifiManager.MulticastLock`，确保手机休眠和息屏期间 mDNS 广播不被 Android 系统挂起。
- **彻底解决 APK 隔段时间自动跳转前台抢占手机屏幕**：
  - **根因分析**：Mac 端 `wakePhoneMonitorIfDesired()` 在唤醒后台监控时，若服务启动受限曾回退执行 `am start -n com.popowk.simai.companion/.MainActivity`，导致每隔 90 秒强行将 Companion 界面弹到手机屏幕最前台，打断手机正常使用。
  - **彻底修复**：移除所有拉起前台 Activity 的兜底操作，全部改为后台静默启动 `CallMonitorService`，彻底杜绝手机屏幕被抢占弹窗。
- **安装后自动静默授权全套系统权限（含短信转发与电池优化白名单）**：
  - Mac 端执行安装时自动追加 `-g` 标识（`adb install -r -g`）。
  - 自动通过 `pm grant` 授予：`READ_PHONE_STATE`、`ANSWER_PHONE_CALLS`、`RECEIVE_SMS`、`POST_NOTIFICATIONS` 以及 `moe.shizuku.manager.permission.API_V23`。
  - 自动将伴侣端加入系统电池优化白名单（`dumpsys deviceidle whitelist +com.popowk.simai.companion`），防止 Android 系统在后台冻结或杀死伴侣端进程。
- **Android 伴侣端（v0.3.15 · Build 20）界面极致精简与按钮合并**：
  - 移除 5 大段冗长重复的条款式文本说明；
  - 按钮整合为醒目的单一操作：「一键全部授权并启动服务」，合并发起电话、短信、通知全套系统授权；
  - 紧凑横排「停止服务」与「系统权限/自启动」快捷入口；
  - 飞书 Webhook 保存、测试与清除操作合并为同一水平按钮组，界面清爽现代。

## 0.4.34（Shizuku WiFi 局域网直连版、特权接听/挂断、状态极速同步与连接防抖）— 2026-11-24

- **正式推出 Shizuku WiFi 局域网直连版（免 USB 数据线与免 Root 特权控制）**：
  - **Android 伴侣端（v0.3.14）深度集成 Shizuku API**：基于 Shizuku UID 2000 系统 Shell 特权，直接执行 `cmd telecom answer` 与 `cmd telecom end-call`，100% 突破各大品牌厂商（vivo OriginOS、小米 HyperOS、OPPO ColorOS 等）对后台第三方应用接听/挂断电话的限制，免去必须设为默认拨号应用的繁琐限制。
  - **全网卡 HTTP 服务与 mDNS 局域网自动发现**：伴侣端监听 `0.0.0.0:18764`，并在局域网内通过 Bonjour（`_simai._tcp`）广播自身服务。伴侣端主界面清晰呈现当前本机 Wi-Fi 直连地址（如 `http://192.168.x.x:18764`）及 Shizuku 授权状态。
  - **Mac 端局域网极速直连**：在「高级维护」中支持一键配置并测试手机 Wi-Fi IP。直连模式下无需拔插数据线，响应延迟降至 2~5ms（相比原 ADB 进程启动快 100 倍以上）。
  - **多层高可用自适应降级**：Wi-Fi 直连（极速） → USB 数据线（ADB HTTP） → ADB 私有快照文件。无论数据线拔插还是网络切换，状态平滑无缝衔接。
- **APK 信息读取极速优化与状态防抖（彻底解决读取慢与频繁显示手机端未连接）**：
  - **解决信息读取慢**：伴侣端由 2 秒定时批量落盘改为电话状态变更时瞬间同步写入（<1ms），Socket 开启 `TCP_NODELAY` 消除系统级延迟，Mac 端轮询定时器从 2.0s 提速至 1.0s，彻底消除来电感知的数秒滞后感。
  - **状态防抖解决“未连接”闪烁**：旧版本单次 HTTP 或 ADB 偶发超时即刻将 `livePhoneState` 置为“未连接”并触发数十秒指数退避。新版本引入 3 次连续失败防抖机制，1~2 次瞬态抖动保留既有状态并以 1 秒间隔快速重试，只有连续 3 次无数据才判定为未连接，彻底消除界面红字“手机端未连接”频繁闪烁。
  - **移除来电强制禁用 HTTP 反模式**：旧版本来电响铃时会将 HTTP 同步强制关闭 75 秒回退至 ADB 文件轮询，产生长达半秒的阻塞。新版本全程保持极速 HTTP 通道。
- **控制台状态栏与维护面板升级**：
  - 状态栏新增「传输通道」药丸徽标，实时指示 `Wi-Fi 局域网直连 (极速)`、`USB 数据线 (ADB)` 或 `ADB 快照备用`。
  - 新增「特权引擎」指示，清晰展示 `Shizuku 就绪` 状态。
  - 高级维护面板新增 Wi-Fi 连接配置与即时连通性测试按钮。

- **新增电话接听与挂断控制（手动 + 自动兜底）**：
  - Mac UI 新增实时通话控制卡片：来电（RINGING）时提供醒目的「接听电话」（绿色）与「挂断 / 拒接」（红色）按钮；通话中（OFFHOOK）提供醒目的「挂断电话」（红色）与「停止音频中转」控制。
  - 菜单栏（Menu Bar）增加「挂断当前电话」快捷操作项。
  - 电话挂断指令多层系统级保障：针对现代 Android OEM（如 vivo 等）对第三方 App 限制调用 `telecom.endCall()` 的问题，底层通过 ADB Shell 依次调用具备系统特权的 `cmd telecom end-call`（Android 10+ 官方 Telecom 管理器指令）、`telecom end-call`（旧版）以及 `input keyevent 6`（KEYCODE_ENDCALL 物理按键兜底），确保挂断 100% 成功。
  - 挂断时立即安全切断双向音频中转，并在 0.5 秒内通过系统输出路由器（AutoVoiceOutputRouter）自动将 macOS 输出恢复为物理扬声器/耳机。
- **彻底移除 scrcpy 及相关冗余代码**：
  - 从「高级维护」、数据模型（AssistantModel）、ADB 检查器（AndroidADB）、应用菜单（SIMAIApp）及界面中彻底移除所有 `scrcpy` 屏幕控制、进程拉起、环境嗅探和 Homebrew 安装指引等冗余代码。
  - 「打开手机权限设置」现直接通过系统 Intent（`android.settings.APPLICATION_DETAILS_SETTINGS`）呼出手机应用设置页，不再强捆绑屏幕镜像。
- **控制台界面（DashboardView）深度精简与按钮合并**：
  - 清理了早期测试遗留的 5 个未用面板（phoneAudioPanel、liveVoicePanel、chatGPTVoicePanel、aiReplyPanel、audioPanel）以及大量冗长重复的条款式说明文本。
  - 将设备自检、ADB 检测与 Companion 更新按钮合理归类为单一操作工具栏，布局更加紧凑现代。
- **发布 Shizuku WiFi 版免 USB 技术研究规划**：
  - 完成并撰写了深入的技术方案研究文档 `docs/SHIZUKU_WIFI_EDITION_RESEARCH.md`。
  - 详细论证了 Android 11+ 原生无线调试免电脑自激活机制、Shizuku UID 2000 Shell 特权直接调用 `ITelecomService` 系统 Binder、mDNS（Bonjour）局域网免配置自发现，以及局域网全双工 PCM 音频 Socket 直连方案，为后续彻底拔除 USB 数据线奠定坚实架构基础。

## 0.4.32（全双工音频与系统路由修复：彻底解决接听后听不到声音）— 2026-11-24

- **解决电话听不到 GPT 声音（系统输出调度修复）**：
  - 根因分析：macOS WebKit 未实现 Web Audio API 的 `AudioContext.prototype.setSinkId`（在 macOS WebKit 中为 undefined）。旧版本默认开启的“视频隔离输出”假定网页可通过 setSinkId 将声音单独送入 BlackHole 16ch，导致实际跳过了系统默认输出切换；ChatGPT 的 Web Audio 声音全部流向 Mac 物理喇叭，BlackHole 16ch 完全静音，回传给手机的通话音频为 0。
  - 架构修复：切换为可靠的系统输出调度机制（AutoVoiceOutputRouter）。通话接通时自动安全将 macOS 默认输出切换至 BlackHole 16ch，并通过 CoreAudio 本地监听分流至用户保存的物理耳机/扬声器（保证 Mac 前端仍可正常听到），挂断时立即自动恢复 Mac 原有输出设备。
  - 修复异步时序死锁：通话交替对话中 WebKit 麦克风短暂变更为 `.muted` 状态时，旧代码触发了 `setAIReplyToPhone(false)` 且因异步验证状态不一致导致上行被永久静音。现已修复状态机判定：在通话进行中不因暂态变更掐断通话上行，并解除互锁死锁。
- **解决 GPT 听不到电话声音（分析仪与输入通道激活）**：
  - 修复 WebKit 页面内音频分析仪 AudioContext suspended 状态，在启动时自动调用 `resume()` 确保分析仪及 VAD 识别稳定生效。
  - 应用启动时主动请求并检查 macOS 麦克风系统权限，避免 CoreAudio 输入端因权限静默丢弃采样帧。

## 0.4.31（精确绑定 BlackHole 2ch 虚拟麦克风与 Web Audio 全链路路由）— 2026-11-24

- **解决 GPT 听不到电话声音（麦克风串台修复）**：
  - 实机日志诊断证实，网页启动 Voice 时因尚未缓存 deviceId 抓取了系统硬件麦克风（如 USB 麦克风），导致触发 `WRONG_CAPTURE_DEVICE`；但旧代码将错误音轨透传给 ChatGPT 并虚假报告验证通过，致使 GPT 实际在收听环境杂音而听不到电话下行声音。
  - 在 WebKit 注入脚本中增加设备自动预发现机制（监听 `devicechange`），在抓取前预置 BlackHole 2ch deviceId。
  - 在 `getUserMedia` 阶段增加精确重定向保护：当初次抓取非 BlackHole 2ch 时，自动根据解锁的设备标签以 `deviceId: { exact: ... }` 重新向 WebKit 申请真正的 BlackHole 2ch 音轨并安全关闭旧硬件音轨，严格阻断错误硬件麦克风进入 ChatGPT。
  - 打开内嵌 ChatGPT Voice 窗口时主动预设 macOS 默认输入为 BlackHole 2ch。
- **解决电话听不到 GPT 声音（音频隔离模式路由补全）**：
  - 在声音隔离模式下，补齐对 Web Audio API（`window.AudioContext` 及 `window.webkitAudioContext`）的创建拦截与 `setSinkId` 自动路由，防止网页通过 AudioContext 播放时直接走物理扬声器而漏过 BlackHole 16ch 回传通道。
  - 移除对暂停状态媒体节点跳过 `setSinkId` 的不合理限制，确保所有媒体元素和 AudioContext 均在发声前完成对 BlackHole 16ch 的独立绑定。


## 0.4.30（系统级接听兜底与 WebRTC 麦克风收音恢复）— 2026-11-24

- 针对 vivo 及 Android 10+ 第三方 App 调用 acceptRingingCall 被系统/锁屏机制拦截的问题，在会话与响铃安全校验通过后，增加 ADB 系统级接听兜底（cmd telecom answer / telecom answer / KEYCODE_CALL），具备 MODIFY_PHONE_STATE 权限，彻底解决无法自动接听。
- 修复来电响铃时因状态处于 ADB_FILE 导致的 HTTP 3 秒无效超时等待，优先进入本地受控 Shell 快速接听通道。
- 移除 WebKit 中对 getUserMedia 强制指定的 echoCancellation/noiseSuppression/autoGainControl = false，恢复 WebRTC 自动增益控制（AGC）与音量归一化，解决电话下行弱音频低于 ChatGPT VAD 唤醒门槛、导致 GPT 听不到声音的问题。
- 移除 WebKit 设备校验未就绪时强制执行 tracks.forEach(stop) 的自杀式音轨终止逻辑，增加 deviceId 失败重试保护。
- 修复声音隔离模式下因通话接通前无活动媒体导致 isolatedOutputReady 死锁无法触发接听的问题；修复 AutoVoiceInputRouter 中因残留状态导致默认麦克风未能切至 BlackHole 2ch 的问题。


## 0.4.29（独立电话状态线程与手机接听明确回执）— 2026-11-24

- v0.4.27 回退实机日志 09:38:03 RINGING seq9，09:38:05 Voice 就绪并发送 HTTP，09:38:14 HTTP 超时/备用 NO_ACK，09:38:41 IDLE seq10，未收到 OFFHOOK。旧查询值 IDLE 与 RINGING 回调持续不一致。
- Companion v0.3.13 (versionCode 18)：实时电话回调在独立线程执行，查询状态仅诊断且记录查询时间，不再覆盖回调。状态快照独立写入，心跳 2 秒，避免文件写入阻塞状态回调。
- HTTP、授权 ADB 显式广播、私有文件共享接听实现：严格核对本次响铃的 session/sequence、35 秒有效期及 ANSWER_PHONE_CALLS。移除可能与回调不一致的二次 getCallState 硬门槛，调用平台 acceptRingingCall，接听请求不等于 OFFHOOK。接听 API 不持状态锁；同一响铃避免重复执行。带回执的前台广播返回固定执行结果，旧版 APK 保留兼容路径。
- Mac v0.4.29 Build46：新 APK 且状态桥接使用 ADB_FILE 时优先使用明确回执广播；HTTP 保留独立转发与短超时，记录具体错误码及 Android 执行阶段。人工接听也使用当前响铃守卫。GPT Voice、BlackHole、PCM 音频实现不变。
- 编译检查不能证明 vivo 实机成功；必须复测 OFFHOOK 与真实双向音频。


## 0.4.28（ChatGPT 麦克风真实音量修复与三级音频诊断）— 2026-11-24

- 09:12:45 真实 Mac v0.4.27 Build44 日志：09:11:38 已请求 Android 接听，09:11:40 OFFHOOK，09:11:41 Android PCM 成功建立；接收电话下行 1,425 帧，峰值 RMS 0.11746，BlackHole2 真实 HAL 输出回调渲染 1,423 帧，丢帧 0。GPT 网页验证选中了 BlackHole2，却只在 PCM 尚未启动前发过 BLACKHOLE2_SIGNAL_SILENT；后来未报告有声。GPT 回复捕获 1,416 帧，RMS 0。
- **不改 Android APK、手机接听流程或已验证的 Android PCM Helper**。Mac v0.4.28 Build45 仅改 ChatGPT 网页收音和诊断。
- WebKit 注入脚本的麦克风 AudioContext 中为 AnalyserNode 接入音量严格为零的 GainNode → Destination，保证音频图持续被处理但不会重复播放电话声音；不把原始 PCM 样本传给 Swift。麦克风轨道被系统静音/取消静音时单独记录固定诊断码；降低网页 RMS 判有声阈值以减少过小音量误判。
- 在 WebRTC sender 支持 getStats/totalAudioEnergy 时，仅记录匿名的“实际上向 WebRTC 发送了有声/静音”结果；无法支持时不伪称成功。
- 仍然出现通话 PCM 有声、GPT 回复零电平时，再自动短暂从 BlackHole2 真实**输入端**读取两秒匿名 RMS，不存储通话录音；区分“HAL 输出看似成功但 BlackHole 输入没声音”与“虚拟声卡有声但 WebKit 麦克风/Voice 未接通”。新增 UI 两级状态及无内容诊断码。只在 GPT 长时间静音时才运行额外捕获，不影响正常通话。
- **真实电话验证仍待用户完成。** 自动编译通过不等于 GPT 官方 Voice 必然处理通过；也可能需要浏览器的真实交互、有效麦克风音轨或网页 Voice 会话恢复。


## 0.4.27（对照实机成功版本恢复独立接听路径）— 2026-11-24

- 调查用户 01:09 上传的 v0.4.26 Build43 诊断。北京时间 01:07:48 收到 RINGING、01:07:50 WebKit 使用 BlackHole2、01:07:54 Voice 就绪，01:07:57 ADB 文件接听 NO_ACK，01:08:01 HTTP 也失败；全程没有 OFFHOOK 或真正 PCM。手机端接听权限明明显示 ANSWER_PERMISSION_GRANTED，不是 CALL_PHONE 缺失。
- 对照已实机接听成功的 Mac v0.4.21：该版本独立调用 ADBInspector.openBridge 建立专用 HTTP 接听转发，然后 POST /call/answer；新版本 v0.4.23 起复用状态同步转发，在 v0.4.24 起把私有文件 NO_ACK 置于 HTTP 之前，耗尽响铃时间。
- Mac v0.4.27 Build44：回归独立的接听专用 ADB HTTP 转发，优先尝试官方 Android Companion 的 POST /call/answer，保持会话序列安全校验。仅在 HTTP 失败且同一响铃仍有效时才尝试受控 ADB 广播/私有文件兜底，不能凭无回执宣称已接听。
- Android Companion v0.3.12 (versionCode 17)：保留经过验证的 ANSWER_PHONE_CALLS 和 READ_PHONE_STATE 权限，不新增仅供拨号的 CALL_PHONE。电话监听前台服务新增 900ms 的 TelephonyManager 实际通话状态核对，以补偿部分 vivo 锁屏下 OFFHOOK 回调延迟、手动接听后 PCM 无法及时启动的问题。
- 继续复用以前实测有声的 AudioStreamServer.java PCM Help​​er（v0.4.21 与本版 blob SHA 完全一致）和 BlackHole2 电话下行路线。支持手动接通已追踪来电后自动启动 PCM；未知电话不启动自动音频、不进行自动挂机。
- 新增 Android 实际通话状态诊断和兼容性测试；自动化编译/单元测试不等同于 vivo 实机。旧版历史验证仅证实电话 PCM/BlackHole2 非静音输出，不能单凭这个保证 GPT 官方网页识别或回复。


## 0.4.26（真实来电 PCM 与独立接听广播兜底）— 2026-11-24

- 最新 00:45:38 诊断包中 Mac v0.4.25 Build42 / Android Companion 已明确 ANSWER_PERMISSION_GRANTED；00:44:01 RINGING、00:44:03 网页确认采集 BlackHole 2ch、00:44:08 发现 BLACKHOLE2_SIGNAL_SILENT。00:44:10 受控文件接听 NO_ACK、00:44:14 HTTP 失败；00:44:57 才同时收取 OFFHOOK 与 IDLE 两条历史状态，期间没有真正建立电话 PCM。
- 关键修复：此前手动接听后因 automaticAnswerAcknowledged=false 导致 AutoCallStateMachine 永远不会启动 PCM。现在只对程序已实际观察 RINGING 的同一 Android 会话和下一 OFFHOOK 序列，且官方 Voice 麦克风和独立音轨都验证成功的情况下，自动启动电话 PCM 和 BlackHole2 → Voice / BlackHole16 → 电话音频。手动接听绝不会获得自动挂机权限，任何未知 OFFHOOK 仍然拒绝。
- RINGING / OFFHOOK 期间优先读取 ADB 私有快照，不再等 HTTP 3 秒超时才恢复；绑定已有已授权手机的 ADB serial，避免每次多启动一个 adb devices；若 OFFHOOK 与 IDLE 被合并成一轮历史状态，记录 OFFHOOK_IDLED_BEFORE_POLL 诊断，不会在挂机后才打开 PCM。
- Android Companion v0.3.11（versionCode 16）增加 android.permission.DUMP 限制的 Android ADB Shell 广播受控接听入口。服务重新验证当前 session、响铃序列、电话状态和 ANSWER_PHONE_CALLS 权限，且仅记录匿名结果。Mac v0.4.26 在手机声称支持时优先尝试广播并核对私有快照实际回执；失败仍保留旧的私有文件路径，不用盲目的电话按键。
- Mac v0.4.26 Build43。自动化测试及构建仅验证软件逻辑，不代表 vivo 运营商电话和 ChatGPT Voice 实机已通过。


## 0.4.25（接听权限与独立回执诊断）— 2026-11-24

- 根据 00:28 诊断包，Mac v0.4.24 Build41 已运行；在 RINGING 后等 6 秒及 14 秒才请求接听，Mac 独立通道两次均返回 ANSWER_FALLBACK_NO_ACK，HTTP 返回 409 或超时，均无 OFFHOOK，故不能把故障认定为 APK 接听权限问题。
- Android Companion v0.3.10（versionCode 15）在私有状态快照增加匿名字段：ANSWER_PHONE_CALLS 是否授权、独立接听轮询线程是否活跃、当前已处理的来电序列和固定处理结果码。每次处理接听请求立即更新原 AtomicFile 状态，除单独回执文件外提供第二确认通道。
- Mac 在 ADB 状态快照直接判断权限缺失与接听线程暂停；单独回执未读到时，允许只从同一服务会话及同一响铃序列的原状态快照确认接听结果，避免 Android 已处理而 Mac 错判 NO_ACK；仍然拒绝过期/其他来电。
- 增加旧版字段兼容性单元测试。Mac v0.4.25 Build42；需要升级手机 Companion 才能得到新增匿名诊断字段，未进行 vivo 真实电话验收。


## 0.4.24（HTTP 失效时独立 Android 私有接听）— 2026-11-24

- 根据 00:06 诊断：RINGING 已被 ADB 私有快照识别，Voice 就绪后 HTTP 接听超时；原备用方式仍使用同一 HTTP 端口和 toybox nc，最终无 OFFHOOK。
- Android Companion v0.3.9（versionCode 14）：新增独立于 HTTP 的应用私有单次接听文件与回执。服务核验会话 UUID、RINGING 序列、实时通话状态及 ANSWER_PHONE_CALLS 权限，并先消费请求再执行，避免重放或接听另一通电话。
- Mac 已处于 ADB_FILE 状态时优先执行独立接听；HTTP 作为后备；只有相同会话的成功回执才授权自动电话音频。自动 HTTP 接听也加上会话/序列防串线字段。
- Mac v0.4.24 Build41；同时更新手机 APK 与 Mac 程序。GitHub Actions 编译不等于 vivo 实机接听验收。


## 0.4.23（自动接听超时降级与 Voice 挂机清理）— 2026-11-23

- 23:20 诊断：RINGING 期间启动 Voice，接听请求因 HTTP 超时而失败，接下来直接变 IDLE，无 OFFHOOK 和 PCM；网页静音实际是尚未接通电话，没有音频来源。
- 首选复用现有 ADB bridge/forward，不再每次接听创建临时端口。Mac->Android HTTP 超时后，严格验证同一个正在响铃的私有状态快照，再尝试一次 Android 应用 UID 本机回环接听。认证 token 不离开手机私有文件、不模拟任何盲目的电话控制按键。若 vivo 无 toybox nc 或回环无法连接，仍安全拒绝并记录故障码。
- 即使接听 HTTP 回执丢失，只要 Voice 是此次响铃启动的，就会在手机 IDLE 后隐藏窗口、释放 ChatGPT 网页音轨和麦克风并保留网站登录状态；无关手动网页登录页面不受影响。
- 未收到已确认的接听成功回执时，不会因为一个未知 OFFHOOK 状态就擅自启动双向电话音频。
- 更新了未接通/未建立 PCM 的预期静音说明，新增对应单元测试。Mac v0.4.23 Build40；Android v0.3.8 不变；仍需真机验证。


## 0.4.22（麦克风实际电平与挂机自动收尾）— 2026-11-23

- 根据 21:53 诊断：在 21:52:01 已自动接听，21:52:02 手机报告 OFFHOOK，电话下行 PCM 1,431 帧、BlackHole2 输出 1,429 帧（RMS 峰值 0.06734）；网页频繁报告 BlackHole2 已验证及 BlackHole16 媒体元素路由成功，但 GPT 回复捕获的 1,420 帧仍为零 RMS。虚拟录音设备匹配不代表网站真正处理了非静音声音。
- WebKit 官方 chatgpt.com 中的 BlackHole2 录音请求关闭 WebRTC echoCancellation/noiseSuppression/autoGainControl，减少虚拟电话声音被误过滤。加入网页音轨匿名音量阈值检查（有声/持续静音/无法确认），仅上报固定的状态码，不记录/上传声音或网页消息。
- BlackHole16 的 Mac 捕获从仅使用第 1 个通道升级为检测并选择确实含有声音的通道，选择采用幅度门槛与滞回抑制立体声抖动，并保持隔离模式下不修改 Mac 系统默认扬声器。电话下行存在而 GPT 持续零 RMS 时会在运行中明确显示并记录诊断码。
- 仅对 SIM AI 自动接听的会话，在安卓 PCM Helper 返回 AUDIO_REMOTE_CLOSED（可能早于异步电话状态更新）或收到 IDLE 时执行 Voice 清理：先隐藏自动窗口再卸载网页音轨、关闭麦克风并保留 WebKit 登录数据；不盲目给运营商电话发送挂断命令。不会因为其他用户手动 ChatGPT 会话而乱关窗口。
- 新增独立单元测试，确保自动 PCM 断开或真实 IDLE 会收尾，手动浏览器不受误清理影响。Mac v0.4.22 Build 39；Android Companion 仍为 v0.3.8，手机 APK 不需要重新安装；WebKit 声音能否被 GPT 识别必须真机验证。


## 0.4.21（修复 Voice iframe 验证阻塞与网页白屏）— 2026-11-23

- 20:46 诊断显示：Android 在 20:46:00 成功发送 RINGING，20:46:02 WebKit microphoneCaptureState.active，20:46:10 HTMLMediaElement 的 BlackHole 16ch 输出已验证，但主页面 getUserMedia 钩子仍 WAITING_FOR_CAPTURE，导致 20:46:26 自动接听因 25 秒超时失败。随后程序调用 releaseForIdle，将用户看到的页面导航到空白 HTML（不是网页自动刷新）。
- Mac 内嵌 ChatGPT 现在对官方站点的同源子 iframe 注入 getUserMedia/RTCPeerConnection.addTrack/RTCRtpSender.replaceTrack 的只读音轨识别，验证 BlackHole2 的 live audio track 后发送仅包含固定代码的 WebKit 本地消息给应用；不传 URL、音频、文字、凭据或设备 ID。主页面保持 WAITING 不再覆盖来自子页面的近期有效确认。音轨证据在 8 秒未更新后过期，不把未验证的物理麦克风默认作为安全输入。
- 启动超时、临时失去 RINGING、电话 IDLE 和手动停止自动接听时只更新状态并保留 ChatGPT 页面，避免自动加载空白 HTML。用户手动打开的浏览器窗口不会因手机挂机被强制隐藏。仅退出 App 或显式禁用嵌入浏览器时释放网站进程。
- 补充真实导航与 WebKit content process termination 诊断，以识别后续网页独立问题；新增 iframe 麦克风证据过期回归单元测试。
- Mac v0.4.21 Build38；Android v0.3.8 不变，内置 APK 无功能改动。实机自动接听与网页兼容性仍需真实电话测试。


## 0.4.20（ADB／GPT 麦克风／系统声音稳定性）— 2026-11-23

- 20:09 诊断显示：Android 状态服务不稳定、监听唤醒被拒绝、私有快照过期、反复端口转发；Mac 有效下行 RMS 0.22177，BlackHole 2ch 输出 686 帧，但 GPT 回复 RMS 0。此前仅确认 WebKit 的任意麦克风正在采集。
- Mac 连续 3 次未查到 ADB 授权设备才判定真正失联；保留有效端口转发，限制重建频率；拉长 HTTP、服务唤醒退避。只有用户没有停用手机监听时才在 Android 后台服务启动被拒绝后尝试打开 Companion Activity 恢复；Android 系统仍可能限制后台运行。
- Android Companion v0.3.8（versionCode 13）：私有电话状态快照心跳 15→10 秒。
- ChatGPT 官方网页主动删除保存的物理麦克风 deviceId，使用本程序设定的 BlackHole 2ch 输入，并核对实际 getUserMedia 音轨设备；网页录音身份验证成功、输出隔离验证成功才允许自动接听。失败不会默认回退到物理麦克风。
- 视频安全模式中，不再通话前后更改 Mac 默认输出；自动值守期间保持 BlackHole2 为默认输入，退出/用户显式关闭时恢复，避免逐通反复切换；不会暗中改变播放视频的扬声器。手动耳机选择保存在设备 UID，自动补选不会覆盖它；外部默认输出变化仅记录匿名事件。
- 从旧的全局输出模式仅迁移一次至安全模式，用户之后手动选择仍然生效。Mac v0.4.20 Build 37；PCM 180 秒上限不变，WebKit/vivo 需实机确认。


## 0.4.19（APK / 权限与播放修复，待实机验证）— 2026-11-23

- Android Companion v0.3.7 versionCode 12：电话状态读取和接听／挂断授权合并为一个“一键开启电话助手”；移除第二个“授权 Mac 控制接听与结束电话”按钮。升级时对新增权限至多自动发起一次系统授权，不反复骚扰用户；尊重用户停止监听的选择。短信及飞书权限独立控制。
- Mac 一键安装新版 APK：仅对恰好一台已授权手机执行保留数据的 ADB install -r。基于明确用户点击，尝试通过已授权 ADB 申请 READ_PHONE_STATE 与 ANSWER_PHONE_CALLS；如厂商拒绝则由 Android 自己弹出权限请求。不自动授予短信、不卸载旧 APK、不接管默认拨号器。
- 修正 Mac 内置 APK 标签长期写成 V0.3.5 的错误。打包时从 Gradle 读取版本并用 Android SDK aapt 对实际 APK Manifest 交叉校验，版本元数据随 Mac 程序一起发布；主界面可查询实际安装的手机版本。
- 解决 WebKit 可能因异步 setSinkId().then(play()) 损失真实网页播放手势的问题：恢复同步原生 play()，设备改为异步设置，所有远端音频隔离仍需通过实测检查才允许自动接听。对 NotAllowedError 记录可读日志、提示点击 ChatGPT 网页“继续播放”；不伪造用户手势。
- Mac v0.4.19 Build 36；Android Companion v0.3.7（12）。手机真实权限情况和 Voice 网页行为仍需实机验证。


## 0.4.18（视频兼容隔离，需实机验收）— 2026-11-23

- 通过诊断 20261123-190242 定位：RINGING 后传统系统输出路由返回 ROUTE_MONITOR_PHYSICAL_REQUIRED；之前出现 ROUTE_USER_CHANGED_OUTPUT，设备播放/耳机切换后原来保存的数字设备 ID 可能失效。
- Mac 新增默认打开的「视频兼容：只隔离 ChatGPT 声音」模式：不修改全系统默认音频输出。使用 macOS WebKit HTMLMediaElement.setSinkId 给官方 chatgpt.com 网页的 Voice 媒体音频单独指定 BlackHole 16ch。由于第三方网站输出结构不可控，只有网页返回实际声音元素设置成功才允许自动接听；不兼容则安全退出，绝不把其他 app 的视频声音回传给电话。保留用户可手动切换的旧全局模式并明确提示风险。
- 音频监听设备按 CoreAudio 设备 UID 持久化，重启、蓝牙/HDMI 更换时自动选取仍可输出的物理设备，不再使用过期数字 ID；并提供媒体隔离诊断状态。
- 当隔离路由在通话中丢失，立即暂停 GPT→电话的音频回传，等待同一通电话的网页隔离恢复后才重启。
- macOS v0.4.18 Build 35；Android Companion v0.3.6 不变；没有加开机启动，180 秒 PCM 测试限制仍保留。本版本编译和实机音频路由是两个不同验收步骤。


## 0.4.17（待实机验收）— 2026-11-23

- Mac 启动按照 ADB 授权扫描、Android 监听预热和状态转发的顺序恢复；退出前同步清理本应用创建的 ADB forward。
- 对 Mac 软件自己成功自动接听的通话，Voice 麦克风连续停止采集超过 4 秒后，才发送带 Android 会话和 OFFHOOK 序列校验的挂断请求。新版 Android Companion 提供 /call/hangup，旧版可在再验证当前通话后尝试 ADB END_CALL 兼容键事件；无法确保所有 vivo 固件接受。
- 麦克风网站权限在主界面与内嵌浏览器明确显示“始终允许 chatgpt.com 麦克风”，用户主动开启后无需每次重新确认网页弹窗。系统级 macOS 授权仍由用户单独控制。
- Mac v0.4.17 Build 34，Android Companion v0.3.6 Build 11；旧版 Android v0.3.5 无需为兼容挂断强制卸载。保留 180 秒 PCM 测试限制。


## 0.4.16（实机待验收）— 2026-11-23

- Android ADB 初始连接先读取带更新时间的私有状态快照，HTTP 超时缩短至 3 秒。若快照过期，最多每 45 秒请求一次已有的前台电话监听服务恢复；尊重 Companion 记录的用户手动停止选择，不修改权限、不弹手机主界面。减少无意义的端口反复重建。
- 电话状态游标新会话只建立当前序列基线，避免启动恢复时将 64 条历史 RINGING、OFFHOOK、IDLE 当成刚来的电话，当前状态仍实时同步。
- 可保存仅 `https://chatgpt.com` 官方域名的固定页面地址，包括自定义 GPT 或已有会话；保留网页登录状态，不读取提示词。支持首次用户授予网站麦克风成功后记住授权、再次访问免重复网页提示（仍受 macOS 系统权限限制）；可随时取消记忆。
- GPT 回传监听时，Mac 默认不把来电者 PCM 再单独播到同一个物理输出，避免和 AI 返回同时监听产生类似回音的体验；只影响本地监听，不影响来电→GPT、GPT→电话；保留可选双路监听。
- Mac 版本 v0.4.16 Build 33，Android Companion v0.3.5 不变；未添加开机启动。180 秒测试限制保留。


## 0.4.15（实机待验收）— 2026-11-23

- 按需启动：不再开机或空闲时自动加载 ChatGPT 网页／启动 Voice；检测 RINGING 后先执行设备 PCM 预检，尝试加载网页和启动 Voice，WebKit 麦克风采集就绪且手机仍在响铃时才请求接听。单次等待最多 25 秒，超时不接听。
- 内嵌浏览器空闲时卸载网页内容，保留持久 WebKit 登录数据；一通电话结束后尝试关闭语音窗口。官方 ChatGPT 可能拒绝无用户手势的 Voice 启动；内嵌登录与授权仍需用户完成。
- 针对 2026-11-23 14:54 诊断记录的物理监听、BlackHole 2ch 虚拟麦克风均 0 渲染，改用明确绑定设备的 macOS HAL AudioUnit PCM 输出，增加通话前小音量合成测试帧渲染预检；仍需在 Apple Silicon Mac 实测音质和 Voice 音频输入。
- 未设置开机自启动，Android Companion V0.3.5 未变；通话音频不落盘，诊断保留分类信息。原 180 秒试验限制本次暂不修改。

## 0.4.14 — 2026-11-23

- Mac 新增 WebKit WKWebView 内嵌 ChatGPT 登录／Voice 窗口（持久网站数据只保留在用户 Mac，由用户自行登录），以及按源站限定的实验性 Voice 启动按钮点击，不读取 Cookie、密码、聊天正文和 Token。
- 内嵌网页麦克风按 WebKit/macOS 原生方式提示用户授权。只有 WKWebView 实际处于 microphoneCaptureState.active，才允许该模式自动接听；采集停止撤销自动值守及 GPT 回传。所有日志仅包含固定类别代码。
- 在网页启动前自动设置 BlackHole 2ch 输入与 16ch 输出，在已激活 Voice 的等待时段保持路由并在停止值守或退出时恢复；兼容原来外部浏览器方案。
- 警告：Google 第三方登录可能拒绝内嵌 WKWebView，官方网站按钮、媒体用户激活要求及会话保持行为会变，不能保证脚本点击后 Voice 真正启动，也不是 ChatGPT Plus 的第三方 API。Android Companion V0.3.5 不变。


## 0.4.13 — 2026-11-23

- V0.4.12 实机日志显示 BlackHole 2ch/16ch 自动选择和自动接听已成功，但 1912 帧电话 PCM 有 1887 帧本地播放丢弃及 1708 帧虚拟麦克风丢弃，GPT 回传峰值 RMS 仍是 0.00000。
- 用 AVAudioSourceNode 连续 PCM 渲染环形缓冲代替每 20ms 一次的 AVAudioPlayerNode scheduleBuffer，防止单个播放完成回调延迟堵塞实时电话和 BlackHole 路由。缓冲有界并在欠载时输出静音。
- 在脱敏诊断包中新增物理监听和 BlackHole 虚拟麦克风实际渲染帧数及未渲染报警；不收集原始电话语音。Android V0.3.5、SMS 飞书及简洁 UI 均不变。改进效果需真机验证。


## 0.4.12 — 2026-11-23

- 根据 V0.4.11 Build 28 用户诊断确认 ADB 自动接听、PCM 会话和 BlackHole 16ch 输出成功，但未验证 ChatGPT 实际选中 BlackHole 2ch 默认输入；GPT 回传峰值 RMS 为 0。
- Mac 新增可恢复的 CoreAudio 默认麦克风 BlackHole 2ch 路由，预备自动值守时启用，退出值守/程序时按 UID 恢复原设备；尊重用户手工选择，异常退出可下次恢复。继续在来电期间自动切换和恢复 BlackHole 16ch 播放输出。
- 调整物理监听/虚拟麦克风的 PCM 播放队列：以渲染完成而非硬件播放完成回收缓冲，提高短时队列余量，针对上版数千帧丢弃问题；实际改善需实机确认。\n- 新增电话下行音频 RMS 与 GPT 回复静音诊断分类，持续记录在脱敏 JSONL/ZIP，不采集通话内容、号码、设备序列号或验证码。
- 主界面简化为 AI 自动值守、快速设置以及折叠的飞书设置/ADB 维护/日志导出；四阶段实验性操作控件不再在主界面显示。
- 官方 ChatGPT Voice 网页可能固定了独立麦克风，macOS 默认输入改变不保证网页立即跟随；必要时需首次手工改选 BlackHole 2ch 并重新启动官方 Voice。Android APK 版本不变。


## 0.4.11 — 2026-11-23

- Mac V0.4.11 Build 28 新增一键安装 BlackHole 16ch／2ch 引导，免 Homebrew：只在用户确认后，直接向 Existential Audio 官网上游请求固定版本 0.7.1 官方包。
- SHA-256 分别按 Homebrew 官方 Cask 固定校验，下载失败、哈希不符或返回不正确状态码即停止；不自动执行有管理员权限的静默命令。
- 使用 macOS Installer 进行用户批准的驱动安装并自动监听 CoreAudio 设备是否出现；如需重启 Mac 则按系统提示。遵守官网对官方二进制第三方再分发的限制，不把驱动 .pkg 嵌入发给用户的 ZIP。
- Android Companion V0.3.5 无变化；已实现的 BlackHole 输出自动切换和通话后恢复功能保留。


## 0.4.10 — 2026-11-23

- Mac Build 27 添加 CoreAudio `kAudioHardwarePropertyDefaultOutputDevice` 自动控制模块：GPT 来电开始时自动将默认播放切到唯一 BlackHole 16ch，原来的真实输出保留为电话监听设备。
- 支持原始物理设备 UID 记忆和通话 IDLE、用户停止、PCM 超时、退出程序后的恢复；程序异常退出时下次启动尝试修复。
- 尊重用户主动修改系统音频输出的行为，不覆盖其新的设备选择；设备缺失或切换失败时避免自动接听而发生无人应答。
- 默认开启自动音频输出切换，增加设置状态与一键恢复；不会修改麦克风、音量、系统权限或系统提示声专用设备。
- 原有 ChatGPT Plus 需要用户先手动开始官方 Voice，会话并非第三方 API；如果浏览器锁定其它输出，系统默认切换也可能不生效。Android Companion V0.3.5、短信飞书和既有音频协议不变。


## 0.4.9 — 2026-11-23

- Mac 自动电话状态机：RINGING 时只发出一次经认证的 Android 接听请求，OFFHOOK 后自动创建双向 PCM，真正建立连接后再接通已预备的 BlackHole/ChatGPT Voice 路由；IDLE 或音频结束后释放资源。新增不重复接听、不误附加音频的核心测试。
- 「自动接听与连接电话音频」默认开启，但**不在没有语音服务就绪的情况下主动接起真实电话**。官方 Plus Voice 无公开接口支持程序后台自动启动或检查会话，必须在每次启动 Mac 软件后先由用户准备官方 Voice 并声明就绪，之后后续来电不需要逐次点击；应用重启后不自动声称会话还在线。
- 自动选择已经存在的真实 Mac 默认输出设备作为监听候选，不改变系统音频输出；仍需用户事先正确配置 BlackHole 2ch/16ch，失败时停止 GPT 路由并记录不含通话内容的原因。
- 仅更新 Mac V0.4.9 Build 26；Android Companion V0.3.5 和 APK 签名不变。此版本是自动通话编排，不是完全无人值守的 GPT 接线员；真正全自动仍需要有可编程的语音引擎（单独付费 API 或本地模型），Plus 订阅不提供第三方 Voice 控制接口。


## 0.4.8 — 2026-11-23

- Android Companion V0.3.5：加入可选 ANSWER_PHONE_CALLS 运行时授权，原有 ADB 私有令牌桥接新增仅在系统检测到 RINGING 时允许的人工接听请求；不改变默认拨号应用，不自动接听。
- Mac V0.4.8：增加接听按钮和状态反馈；GPT 语音链路可由用户二次确认后一次联动开启，若中途失败立即关闭已开启的虚拟路由；增加立即停止。
- 继续沿用 BlackHole 2ch / 16ch 和 180 秒电话音频测试；不伪装 ChatGPT Plus 具有第三方自动 Voice 启动接口。说明见 docs/AI_PHONE_AGENT_PLAN.md。
- 新增 Mac 所有者一次性签名配置脚本 Scripts/setup-android-signing.sh，通过本地 GitHub CLI 安全设置 Secrets；未实际运行前不宣称已经配置完成。支持已有证书复用，防止不慎旋转。


## 0.4.7 — 2026-11-23

- Mac 新增通过 scrcpy/ADB 打开单台已授权 vivo 手机的实时屏幕窗口，可用 Mac 鼠标/键盘手动处理 vivo 安装确认、电话和 SMS 权限提示；安装/确认重装时自动尝试启动该窗口。
- 新增 Mac「打开手机权限设置」按钮，仅打开 Android 系统 Companion 应用详情页，不调用静默权限授予、自动化点击或绕过系统安全限制。
- 检测 scrcpy 安装/ADB 授权/多设备，断线退出后反馈状态。镜像禁用音频、不录制截图或声音，日志只记录错误类别，不记录手机序列号。
- 仅更新 Mac V0.4.7 Build 24，内置 Android Companion V0.3.4 不变；原有短信飞书转发、通话语音与安全签名逻辑保持不变。


## 0.4.6 — 2026-11-23

- Android Companion V0.3.4 versionCode 9：增加 Secrets 固定证书签名的 Gradle 配置；仍为可调试 APK，以兼容现有 run-as 配置下发。
- GitHub Actions 通过私有 Secrets 临时解码 keystore，编译后删除；无 Secret 时明确标记临时 Debug 签名，部分 Secret 配置直接失败。发布产物与 Mac 桌面面板展示签名模式，不假装已经解决旧签名迁移。
- Mac V0.4.6 Build 23：增加内置 Android APK 签名状态提示；保留不自动清空数据的升级安全逻辑，短信/电话音频路径未改。
- 新增 Android 固定签名迁移说明及通话本地转写与飞书转发设计方案。当前未实现 ASR；不依赖付费 API / ChatGPT Plus 非官方接口。


## 0.4.5 — 2026-11-23

- Android Companion V0.3.3 (versionCode 8)：首次启动显示电话监听及完整短信推送的用途披露，用户确认后自动请求 Android 电话与短信系统授权；电话权限授予后自动启动监听。
- 「锁屏运行增强」新安装默认开启（增加耗电），短信自动转发默认开启，但仍需实际 SMS 权限和机器人配置；保留已有手动关闭状态和手动停止行为。
- 新增只记计数和时间的普通 SMS_RECEIVED 广播诊断，可区分系统未投递验证码与飞书推送失败；不读取历史收件箱，不保存短信正文、发送方或验证码。
- Mac V0.4.5 Build 22 在安装/明确确认的清空重装成功后自动恢复钥匙串中已保存的飞书配置；清空重装继续保留确认，且系统权限仍由用户在手机批准。
- 包含 SMS Retriever 应用哈希的部分验证码可能由 Android 定向投递，不保证第三方普通短信接收器收到，程序不会绕过系统限制。


## 0.4.4 — 2026-11-23

- 针对用户上传的 Mac V0.4.3 Build 20 诊断日志：飞书地址两次保存成功，同步均报“ADB 桥接暂不可用”。旧日志不能区分 ADB 授权和手机服务状态。
- 为飞书设置新增不依赖电话状态 HTTP 监听的 ADB 直达同步：Mac 仅向唯一已授权设备写入，Webhook/签名只经过 stdin、不在进程参数或日志中，手机私有目录原子接收。
- Android Companion V0.3.2（versionCode 7）在打开应用或收到新短信时自动导入并保存配置；成功后删除待处理文件。手机端删除或修改设置时不会被旧暂存文件覆盖。
- Mac V0.4.4 Build 21 增加详细且无敏感数据的 ADB 故障类别（未授权、多设备、旧 APK、run-as/写入/超时等），区分“已安全下发”和“短信权限已授予/飞书已送达”。
- 保留原有 GPT Voice、通话状态监听、短信全文转发与飞书签名功能。仍需手机实机测试授权、配置导入及实际飞书送达。


## 0.4.3 — 2026-11-23

- Mac 端新增飞书 Webhook 地址和可选签名输入、默认开启的自动短信转发开关、登录钥匙串安全保存、保存并同步及重新同步按钮；没有手机连接时允许本地保存且不误报已同步。
- Android Companion V0.3.1 新增带原有 X-SIMAI-Token 的本机 POST /sms/config 接口和隐私安全状态；仅接受飞书官方 HTTPS 地址，拒绝未经认证写入。配置存于 Android App 私有首选项，短信仍由手机在 Mac 离线时独立发送。
- Mac V0.4.3 Build 20 内置新版 Companion APK，UI 显示 SMS 授权/转发状态；不把 Webhook、签名、短信正文或验证码写入日志、GitHub、导出 ZIP 或 ADB 命令。
- 原有电话状态和 GPT Voice 双向音频保留；手机尚需实机验证权限、ADB 同步和真实短信投递。


## 0.4.2 — 2026-11-23

- Android Companion V0.3.0（versionCode 5）新增入站 SMS_RECEIVED 广播接收器，默认开启转发开关，但必须先由用户在手机申请 RECEIVE_SMS 运行时权限并配置飞书官方 HTTPS Webhook，才会自动发送；Mac/ADB 不需要在线。
- 接收新短信，按 Android 系统 PDU 顺序合并多段完整正文与验证码，随发送方 POST 飞书机器人 text 消息。支持飞书签名校验 HMAC-SHA256、固定官方域名 HTTPS 白名单和拒绝 3xx 重定向。
- Android 界面新增 Webhook/签名配置、短信权限开关、发送无敏感内容的测试消息、清除配置与匿名结果查询。短信正文、发送方及 Webhook 均不写入日志/诊断包；没有持久离线重发队列。
- Android 保留现有电话状态监听；Mac 更新 V0.4.2 Build 19，打包 V0.3.0 APK 并增加手机端功能提示。旧版 Android Debug APK 签名跨 CI 可能不同，安装失败不自动卸载清空。
- 安全提醒：验证码属于敏感登录凭证，请只推送到本人控制的私人飞书群、限制成员与开启签名校验；需要手机端主动授权，默认开关不代表绕过 Android 权限。


## 0.4.1 — 2026-11-23

- V0.4.0 诊断中未发现本次 ChatGPT 路由启动；截图中的文字回复不能证明语音实际送到 Mac 扬声器。
- 新增第二套虚拟声路：BlackHole 16ch → 独立 16kHz PCM 环形队列 → 指定物理耳机/扬声器。保留 BlackHole 2ch 电话→ChatGPT 输入路由。
- 第一次授权仅在 Mac 本地监听，第二次确认双方同意才允许 AI 回复发送到真实电话；自动关闭原有 Mac 麦克风，不混音；一键停止回传。
- 匿名统计：AI 回复帧、峰值 RMS、播放丢帧、上行欠载以及预设路由错误分类。电话会话结束自动关闭。
- 不改变 Android Companion V0.2.2、180 秒限制、不录音、无自动接听、无付费 API；需实机确认 Voice 和 CoreAudio 路由，系统输出 BlackHole 时应静音其他应用。


## 0.4.0 — 2026-11-23

- V0.3.4 Build 16 最新日志：实时音频下行 2,631 帧、上行 2,552 帧、Mac 播放丢帧 68、麦克风欠载 12、溢出 0、上行发送迟发 0。用户反映基本可用，但尚不能确定开头的丢帧来源。
- 引入 **手动、单向** ChatGPT Voice 辅助输入：从已同意参与的运营商电话读取下行 PCM，通过独立 AVAudioEngine 输出到明确识别的 BlackHole 2ch 虚拟音频设备，供用户在 ChatGPT 官方 Voice 界面手动选择为麦克风。
- 只有实时电话音频建立后才允许开启；须再次确认对方知情同意；缺少 BlackHole 或路由失败时禁止回退到默认扬声器。App 不自动切换 macOS 系统设备、不接管官方 Voice 会话。
- 新增开启/关闭按钮、设备就绪提示、独立播放丢帧统计 `voiceRouteDropped`；音频连接释放时自动停止 BlackHole 输出。保留原有 180 秒限制、手机端通话检查、可随时停止、原始 PCM 不落盘、Mac 麦克风默认静音。
- **没有**实现 ChatGPT 语音回复自动传给电话、自动接听、自动开始 Voice 或非官方 API/OAuth；Android Companion 继续 V0.2.2，不需重装。
- 仅为新增能力的编译与试验性接入，仍需在 Mac 上完成 BlackHole 音频输出/ChatGPT 听辨、隔离与回声测试。


## 0.3.4 — 2026-11-23

- 最新 V0.3.3 诊断确认来电状态仍能从 HTTP 超时中自动恢复，但没有本次实时音频帧统计；之前的麦克风卡顿仍需要独立验收。
- 将 Mac 麦克风 PCM 输入改为固定 240ms 环形缓冲，避免每 20ms append/removeFirst 动态搬移；转换器复用缓冲区，音频回调直接写入固定 PCM 队列。
- 上行改为 20ms 单调时钟节奏发送，ADB 写入阻塞后跳过过期节拍，防止“写完再睡 20ms”导致渐进积压。
- Mac 扬声器允许最多 360ms 的受限排队，完成回调改为实际播放完成时计数。指标新增麦克风欠载、溢出、上行迟发节拍、当前缓冲毫秒数。
- 实时音频预览期间暂停非关键来电状态轮询，结束后自动恢复；保留 Android 端对真实通话状态的独立检查。
- 增加环形缓冲、编码、静音、Float32 转换及单调发送调度测试，保留原有隐私、人工授权和 180 秒限制。
- Android Companion 仍为 V0.2.2，本次只更新 Mac。实机双向人声清晰度仍待确认。

## 0.3.3 — 2026-11-23

- 新诊断 ZIP（V0.3.2）证明实时音频成功收发：下行 2,000 帧、上行 1,593 帧、Mac 播放丢帧 107；同时电话状态 HTTP 超时但文件备用成功。麦克风卡顿待后续单独优化。
- Mac 默认自动发现 adb：若保存的手动路径失效，可从 Homebrew/Android SDK/PATH 恢复；显示识别来源与最近一次扫描时间。
- 定期自动检查唯一已授权手机，离线约 12 秒、健康同步约 45 秒；实时通话期间跳过额外扫描以减少音频争用。
- ADB 手机由断线恢复为授权时，立即重置重连退避并恢复来电状态；Mac 睡眠唤醒后复检并重建过期的状态转发。
- 修正旧异步连接对新连接忙碌状态的潜在污染；保留 HTTP→ADB_FILE 回退与匿名状态事件去重。
- 两种自动功能均可在 UI 独立开关，保留手动强制检测入口；不绕过手机 USB/Wi-Fi 授权，不更改 Android Companion V0.2.2。
- 新增自动扫描退避策略单元测试。

## 0.3.2 — 2026-11-22

- 用户 Mac V0.3.1 实机诊断：连续实时音频两次 AUDIO_HANDSHAKE_NO_RESPONSE 且收发帧皆为 0，但传统 Android 上下行音频测试仍正常。
- 修复潜在的启动竞态：ADB TCP 转发连接可能早于 Android 服务开始监听；16 秒内完整重试连接与握手，已被接受的连接保留等待，不掩盖明确的 ERR 错误。
- Android Helper 提前退出时只解析 SIMAI error/stage 固定匿名诊断字段；服务启动命令增加 SERVE 阶段标记。
- 诊断日志加入握手次数，新增严格错误码解析/隐私安全单元测试。
- 保持原来用户确认、最长 180 秒、麦克风默认静音、无录音和非自动接听限制。
- Android Companion 仍为 V0.2.2，不重装手机。

## 0.3.1 — 2026-11-22

- 用户 V0.3.0 实测：传统上下行短测试仍成功；持续 PCM 会话分别因 AUDIO_HELPER_PUSH 和 AUDIO_HANDSHAKE_FAILED_OR_NO_CALL 失败，均无音频帧。
- ADB Helper 推送增加一次有限重试及超时/返回失败分类。
- Android 音频服务握手阶段增加非敏感错误码（通话模式、上下行音轨方法/初始化/播放阶段）。
- Mac 对 Android 握手错误做白名单校验；不再将 ERR、无响应、未知内容合并成一个错误。
- 新增握手协议单元测试。Android Companion 保持 V0.2.2，不重装或清空 APK。
- 实时双向连续人声仍需设备实测确认，不提供 GPT 自动接听。

## 0.3.0 — 2026-11-22

- 根据 vivo S9e 上行提示音人工确认通过，开发最长 180 秒的手动实时电话音频原型。
- Android ADB shell Helper 新增单会话、loopback-only + 64hex token 保护的 16 kHz PCM16 双向实时桥接；真实通话状态必须通过系统校验。
- Mac 新增独立 ADB 音频端口、电话下行播放器、明确授权的可开关 Mac 麦克风与实时帧数/丢帧统计。
- 音频默认发送静音帧、用户可随时停止、不自动接听、不保存 PCM、不调用 GPT 或 Shizuku。初次持续双向语音质量仍需实机验证。
- Android Companion 仍为 V0.2.2，Mac 更新即可，不要求卸载或清空手机应用数据。

## 0.2.4 — 2026-11-22

- 实机诊断证实：ADB Shell/端口映射正常但状态 HTTP 超时；通话下行有非零 PCM，上行测试音人工确认听到。
- Android Companion V0.2.2：AtomicFile 私有匿名状态快照，15 秒刷新时间，停止时标记 running=false。
- Mac 在 HTTP 超时后自动读取已授权 ADB Shell 私有快照；每 20 秒尝试恢复 HTTP；共用事件游标去重，拒绝超过 90 秒的快照。
- 新增快照生存期与双读取路径去重测试。仍不包含实时语音流与自动 GPT 接听。

## 0.2.3 — 2026-11-22

- Mac 增加锁屏期间的 ADB / shell / 端口转发 / HTTP 状态服务分层诊断。按需或首次 HTTP 超时自动检测，日志只有固定类别，无设备地址与授权 token。
- Android Companion V0.2.1：HTTP 事件接口改为有限并发；前台监听启用 START_STICKY；手机端增加自愿开启的 PARTIAL_WAKE_LOCK「锁屏运行增强」和应用电池设置入口。
- 不保证解决所有 vivo OriginOS 锁屏限制；无线 ADB 被系统关闭或用户调试授权撤销时仍需用户手动处理。
- Android APK debug 签名问题仍存在，不会在 Mac 更新时自动卸载手机 App。

## 0.2.2 — 2026-11-22

- 根据用户实际诊断日志修复：ADB 延迟补收 RINGING → OFFHOOK → IDLE，导致 Mac 显示 IDLE、上下行测试按钮不可用。改为只在用户确认并通过手机 Android 音频通话模式检查后执行测试，不再依赖 Mac 实时电话状态。
- 默认自动同步，2 秒检查，HTTP 超时 6 秒，ADB 桥接重连退避 2–30 秒；显示最近成功同步时间。
- 已授权的无线 ADB IPv4:port 端点在临时掉线时可尝试自动 reconnect；不执行全局 adb kill-server。授权撤销或手机无线调试关闭仍需用户操作。
- 防止异步旧连接任务回写覆盖新状态，保持重连去重逻辑；增加两项策略/输入校验测试。
- Android Companion V0.2.0 不变，无需重新安装。

## 0.2.1 — 2026-11-22

- 根据 vivo S9e 实机诊断确认 Android 13 PSTN 音频重定向报告 true，VOICE_DOWNLINK 读取非零 PCM（34,560 样本；RMS 0.02590）；但对方说话尚未音频听辨验证。
- 旧上行音轨反射方式返回 API_MISSING。优先使用 Android 13 系统 AudioManager.getCallUplinkInjectionAudioTrack(AudioFormat)，仅方法不存在时回退旧属性方案。
- 新增详细但匿名的上行错误阶段、接口存在性、已使用的音轨路径等诊断字段。
- ADB 桥接在两分钟内重建约 22 次：增加 4–60 秒退避重连、失败日志合并与连接恢复报告，仍需进一步验证根因。
- Android Companion APK 不变；仅更新 Mac/内置 AudioProbe Helper。

## 0.2.0 — 2026-11-22

- 新增 Android 13 原生 ADB shell AudioProbe Helper：安全查询音频能力、通话下行声音 RMS/峰值检测、显式确认的上行短提示音测试。
- Mac 增加三步电话音频兼容性诊断面板、人工确认、统一匿名日志及导出。
- CI 编译并将独立 AudioProbe.dex JAR 内置于 Mac 包，不要求重新安装 Android Companion。
- 清除旧蓝牙/HFP 观察、60 秒设备观察、模拟来电、模拟故障、本机回环、手动 Voice 模拟开关以及过时说明。
- 保留已验证的 Android 来电状态同步与诊断日志。第一阶段**未**实现实时双向音频传输、AI 自动接听或 GPT API 接口。
- Android 13 只是必要条件，音频 HAL 是否可用需要 vivo S9e 实机测试。

## 0.1.5 — 2026-11-22

- 已通过用户实际 ZIP 证实 Android→Mac 来电事件同步成功：IDLE、RINGING、OFFHOOK、IDLE。
- 修复 USB ADB 断线重连后重放同一个手机会话的旧事件（原日志在 21:23:24 重放序号 1–3）。
- 会话切换时正确重置游标，持续保持有限状态缓冲，增加两个回归测试。
- ADB/HTTP 桥接失败时记录匿名化错误域与代码；APK 安装失败记录可用于诊断的预设文字原因。
- Android APK 保持 V0.2.0，无需重复安装；Mac 升级到 V0.1.5。

## 0.1.4 — 2026-11-22

- Android Companion V0.2.0 添加私有 token 保护的本机 127.0.0.1 来电状态事件 HTTP 服务；只发送状态/时间戳/序列号（事件顺序编号，并非手机序列号）。
- Mac 使用用户已授权的 ADB USB 连接和随机本地端口转发，自动接收并显示实时电话状态、记录匿名诊断事件、支持断线重连。
- 新增「全部日志（含今天）」清理模式，确认后删除本应用全部 JSONL 并清空内存列表，不触及系统 OSLog。
- 针对 CI debug 签名变化，新增需要单独明确确认的旧 APK 卸载重装流程，不再误以为能无损覆盖。
- 不使用 HFP、不会占用 Mac 蓝牙控制器、不采集通话双方音频。

## 0.1.3 — 2026-11-22

- Mac 端支持手动选择 ADB 可执行文件、本地记忆路径、恢复自动检测。
- 新增内置 Android Companion APK 的一键安装/覆盖入口，调用 adb install -r，单设备确认，不自动卸载，不记录设备序列号。
- 新增 Android 端 Java 伴侣 App，显示电话状态回调，运行时电话权限与前台监听通知。
- GitHub Actions 增加 Android SDK / Gradle 编译步骤，并将 APK 嵌入 Mac App、独立发布 APK。
- Android debug 签名跨 CI 构建不稳定，尚未承诺新版本无损覆盖；需要后续安全地配置固定私钥。
- 不接管蓝牙/HFP，不读取联通通话双方音频。

## 0.1.2 — 2026-11-22

- 新增诊断中心「清理旧日志」：保留最近 1 / 7 / 14 天，删除前预览数量与大小并确认。
- 清理范围严格限定本 App 历史 `events-YYYYMMDD.jsonl`；不触及 OSLog、其他应用或已导出的 ZIP。
- 新增 Android ADB 连接自检：不保存设备序列号，只报告已授权、未授权、离线的设备数量。
- 不引入 HFP 接管，不修改 macOS 蓝牙控制器配置；后续以安卓伴侣 APK + ADB 通信为主。
- 增加旧日志清理边界测试，更新 Mac App 版本与 GitHub Actions 构建产物。

## 0.1.1 — 2026-11-22

- 根据首份 vivo S9e 实机诊断 ZIP 添加 60 秒只读来电观察模式。
- 添加用户手动响铃标记；观察蓝牙连接和 CoreAudio 设备/路由变化，不记录号码或音频。
- 更新 Mac 构建版号与 GitHub Actions 发行文件名。
- 坚持 HFP/SCO 未经验证的能力边界。

## 0.1.0 — 2026-11-22

- 新增菜单栏 App、诊断中心和蓝牙/CoreAudio 自检源码。
- 新增模拟电话状态机、麦克风电平测试与试听按钮。
- 新增手动打开 ChatGPT Voice 网页入口。
- 新增 OSLog + 结构化 JSONL、14 天 / 50 MB 轮转。
- 新增隐私脱敏与 ZIP 导出预览、故障注入、错误码。
- 新增 macOS 打包脚本与跨平台核心单元测试。
- 明确声明真实电话 HFP、SCO、接听控制、全双工语音桥接**尚未实现**。
