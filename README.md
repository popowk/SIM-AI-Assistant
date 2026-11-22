# SIM AI Assistant · V0.2.0（Android 13 电话音频兼容性诊断）

**设备目标**：vivo S9e / Android 13 / 中国联通实体 SIM + Apple Silicon Mac / macOS 26.6.2。
**源代码**：https://github.com/popowk/SIM-AI-Assistant

## 已实现并保留

- Android Companion V0.2.0：用户授权的真实来电 RINGING / OFFHOOK / IDLE 监听。
- Mac：ADB 自动检测与手动指定、USB/无线 ADB 授权设备管理、伴侣 APK 安装与覆盖（签名不符时不卸载）。
- Android → Mac：私有通信令牌、本机端口转发、匿名电话状态同步和去重、断线重连。此前 vivo S9e 的真实来电日志已验证此项。
- Mac 本地音频设备检查、麦克风电平、扬声器试听和设备恢复。
- 诊断 ZIP、匿名事件日志、1/7/14 天清理与「清空全部（含今天）」。

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
