# SIM AI Assistant · V0.2.3（Android 13 电话音频兼容性诊断）

**设备目标**：vivo S9e / Android 13 / 中国联通实体 SIM + Apple Silicon Mac / macOS 26.6.2。
**源代码**：https://github.com/popowk/SIM-AI-Assistant

## 已实现并保留

- Android Companion V0.2.0：用户授权的真实来电 RINGING / OFFHOOK / IDLE 监听。
- Mac：ADB 自动检测与手动指定、USB/无线 ADB 授权设备管理、伴侣 APK 安装与覆盖（签名不符时不卸载）。
- Android → Mac：私有通信令牌、本机端口转发、匿名电话状态同步和去重、断线重连。此前 vivo S9e 的真实来电日志已验证此项。
- Mac 本地音频设备检查、麦克风电平、扬声器试听和设备恢复。
- 诊断 ZIP、匿名事件日志、1/7/14 天清理与「清空全部（含今天）」。

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
