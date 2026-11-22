# SIM AI Assistant · V0.3.4（Android 13 电话音频兼容性诊断）

**设备目标**：vivo S9e / Android 13 / 中国联通实体 SIM + Apple Silicon Mac / macOS 26.6.2。
**源代码**：https://github.com/popowk/SIM-AI-Assistant

## 已实现并保留

- Android Companion V0.2.0：用户授权的真实来电 RINGING / OFFHOOK / IDLE 监听。
- Mac：ADB 自动检测与手动指定、USB/无线 ADB 授权设备管理、伴侣 APK 安装与覆盖（签名不符时不卸载）。
- Android → Mac：私有通信令牌、本机端口转发、匿名电话状态同步和去重、断线重连。此前 vivo S9e 的真实来电日志已验证此项。
- Mac 本地音频设备检查、麦克风电平、扬声器试听和设备恢复。
- 诊断 ZIP、匿名事件日志、1/7/14 天清理与「清空全部（含今天）」。

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
