# 变更记录

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
