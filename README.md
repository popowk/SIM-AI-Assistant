# SIM AI Assistant — macOS V0.1.1 (测试工程)

macOS 菜单栏工具：为 Apple Silicon Mac + vivo S9e + 中国联通 SIM 的后续电话辅助实验提供**可运行的 UI、诊断能力和测试基线**。当前版本**不具备真实运营商电话接听、挂断、监听或 HFP/SCO 双向音频桥接能力**。

## 当前实现范围

| 模块 | V0.1 状态 | 实际行为 |
|---|---|---|
| macOS 菜单栏原生 App | 代码已完成，待 Mac 编译实测 | SwiftUI MenuBarExtra 与诊断窗口，LSUIElement 常驻 |
| 蓝牙自检 | 代码已完成，待 vivo 实测 | IOBluetooth 查询已配对经典蓝牙设备和连接状态；**不能判断 HFP 是否可用** |
| CoreAudio 设备自检 | 代码已完成，待 Mac 实测 | 查询音频设备、默认输入输出、采样率和 BlackHole 是否可见 |
| 麦克风测试 | 代码已完成，待 Mac 实测 | 用户主动授权后监测约 1.5 秒 RMS 电平，不保存音频 |
| 本机回环 | 代码已完成，待 Mac 实测 | **用户确认已连接耳机**后运行 2 秒、5% 音量的麦克风→扬声器本地回环；不是电话音频回环 |
| 扬声器测试 | 代码已完成，待 Mac 实测 | macOS 提示音。并非两端通话回环 |
| 模拟来电 | 已完成，跨平台测试通过 | 来电→模拟接听→模拟挂断；**不访问真实电话** |
| ChatGPT Plus Voice | 手动入口 | 打开 https://chatgpt.com/，用户自行登录并点击 Voice；不读取凭据 |
| 日志 | 核心测试通过 | 分级 JSONL + macOS OSLog；14 天 / 50 MB 轮转、独立诊断 ID |
| 导出诊断 ZIP | 核心测试通过 | 脱敏预览、用户确认后 SavePanel，生成 ZIP；不上传 |
| 故障注入 | 核心测试通过 | 模拟蓝牙断连、权限拒绝、音频初始化失败，关联错误码 |
| 故障恢复 | 代码已完成，待 Mac 实测 | 仅用户主动点击，恢复应用启动时备份的默认输入和输出设备；不重置蓝牙 |
| 崩溃诊断 | 当前仅指引 | 避免导出用户其他应用信息，ZIP 内提供手动导出说明 |

## V0.1.1 真实来电只读观察

从首份实机诊断 ZIP 可见，macOS 已发现 vivo 候选设备，但不能证明 HFP/SCO 可用。新增 60 秒只读设备状态观察模式：

1. 在蓝牙面板点击「开始观察」；
2. 使用另一部电话拨打 vivo S9e；
3. 手机响铃时点击「手机已响铃（标记）」，人工接听、挂断；
4. 观察结束后导出诊断 ZIP，查看计数及默认音频设备变化。

该模式不记录手机号、录音、设备名称或敏感设备 UID，不接管电话。变化不等于 HFP 成功；无变化也不能证明不兼容。用户必须主动点击开始与导出。

## GitHub Actions 自动编译与下载

将本仓库 push 到 `main` 后，`.github/workflows/build-macos.yml` 会用 GitHub 提供的 macOS 机器执行测试、交叉编译 **Apple Silicon arm64**、临时签名并打包。可在 **Actions → macOS Build → 最新成功任务 → Artifacts** 下载，也会在 **Releases → Dev Latest** 更新测试发行包。推送 `v*` tag 可创建该版本的 Release。

**注意**：这是未经 Apple Developer ID 签名和 Apple 公证的试验版。macOS 可能阻止首次启动；先核实下载来源及 SHA256，再在「系统设置 → 隐私与安全性」中选择「仍要打开」。不要对不可信的应用执行终端绕过命令。生成 App 并不代表 vivo HFP / ChatGPT Plus Voice 桥接已经可用。

## macOS 编译与运行

需要 Apple Silicon Mac、macOS 13+（目标 macOS 26.6.2）、Xcode Command Line Tools（Swift 5.9+）。无需安装 CocoaPods、Homebrew、BlackHole 或任何 OpenAI API SDK。**本工程是 Swift Package，可直接用 Xcode 打开根目录下的 `Package.swift`。**

```bash
xcode-select --install                     # 如果尚未安装命令行工具
cd SIM-AI-Assistant
bash Scripts/build-macos.sh
open "dist/SIM AI Assistant.app"
```

脚本将执行 `swift test`、`swift build -c release`，组装 `.app`，做本机临时签名并生成 `dist/SIM-AI-Assistant-v0.1.1-macos-arm64.zip`。**临时签名并不等于 Apple 正式公证；不提供面向公众分发的已签名安装包。**

若只做编译检查：

```bash
bash Scripts/verify-macos.sh
```

菜单栏找到电话图标 →「打开诊断中心」。权限提示仅在相关功能确实需要时出现。真实测试前，用 macOS 系统蓝牙设置给 vivo S9e 配对；如果未配对，软件仅显示诊断提示。

## 建议的首轮测试顺序

1. 打开程序、进入诊断中心。验证系统版本、蓝牙配对设备和音频输入输出数量。
2. 依次点击模拟来电、模拟接听、模拟挂断。
3. 分别点击麦克风电平测试（明确授权）、扬声器试听；**连接耳机后**可选本机回环（5% 音量 / 2 秒）；不要把这些结果当作 HFP 回环成功。
4. 使用三个故障注入按钮，每次点「一键导出诊断包」，在预览面板确认后保存 ZIP。
5. 验证 ZIP 包内 `events.jsonl`、`errors.log`、`reproduce.txt`、各项设备快照。故障代码应匹配对应的注入类型。
6. 打开浏览器 ChatGPT，手动触发官方 Voice。记录是否能正常使用浏览器麦克风（与联通通话无关）。
7. **尚不要尝试让软件自动接听真正的电话**；V0.2 HFP 探索完成之前无此功能。

## ZIP 目录结构

```
SIM-AI-Diagnostics/
├── app-info.json
├── system-info.json
├── bluetooth-status.json
├── audio-devices.json
├── events.jsonl
├── errors.log
├── crash-reports/
│   └── README.txt
└── reproduce.txt
```

安全边界：不请求 ChatGPT 密码/OAuth 授权或 API Key；不录音、不采集电话正文、不保存手机号；蓝牙设备名称和 CoreAudio 名称只用于应用本机查看，导出时改为编号。日志里的手机号、MAC、邮箱及常见令牌模式进行自动脱敏；`reproduce.txt` 的用户自由文本只进行规则脱敏，**用户仍应亲自检查 ZIP 后再发送**。原始诊断数据保存在 `~/Library/Application Support/SIM-AI-Assistant/logs/`，默认 14 天 / 50 MB 上限。OSLog 是系统管理的副本，不受 JSONL 的轮转保留策略控制。

## 蓝牙 HFP 与 ChatGPT Voice 的客观限制

- macOS 的 `IOBluetoothDevice.pairedDevices()` 只能列出已配对设备；`.isConnected()` 不能证明 HFP Service Level Connection 或 SCO 音频已建立。
- HFPilot 使用实验性底层蓝牙控制器访问，会令原有外设断开；不作为本项目的 V0.1 依赖，也不在 V0.1 中尝试控制系统蓝牙。
- PhoneBT 是可参考的第三方 HFP 客户端；其代码与具体 macOS、vivo 型号的兼容性都需要独立评估（许可、API、驱动、设备权限与稳定性）。
- BlackHole 仅负责虚拟音频传输，不会自行抓取运营商通话音频。
- ChatGPT 官方 Voice 在 `chatgpt.com` 网页由用户自行启动。Plus 订阅**不能当作第三方开放的 OAuth/API 或可编程语音转发接口**，因此不会在 V0.1 中尝试偷取登录会话或用网页自动化控制 Voice。
- 旧版 macOS Voice 曾在 2026 年 1 月退役，2026 年官方文档已重新介绍不同类型的 Voice in Desktop；这是变化中的产品能力，首版使用网页入口更容易验证。

## 目录结构

```
Package.swift
Resources/Info.plist
Scripts/build-macos.sh
Scripts/verify-macos.sh
Sources/SIMAICore/              # Codable 数据模型、日志、脱敏、ZIP、模拟状态机
Sources/SIMAIAssistant/         # SwiftUI 窗口、蓝牙/CoreAudio、音频测试、模型
Tests/SIMAICoreTests/          # 跨平台 XCTest
```

## V0.2/0.3 开发入口

V0.2 在 vivo S9e 配对后，优先通过可用且合规的 macOS HFP 接口实现实验性 Service Level Connection、来电状态、接听/挂断；必须附开关、超时、恢复机制和独立日志。若系统拒绝 HFP，则保留手动电话辅助，并考虑独立硬件 HFP 网关。V0.3 建立电话下行→Voice 输入和 Voice 输出→电话上行两条**严格隔离**的音频路由，优先验证无回声和手工接管。双向桥接是否可实现取决于真实音频链路与官方 Voice 的权限/产品限制，不能用 V0.1 结果推断。

## 外部官方与开源资料

- OpenAI Voice: https://help.openai.com/en/articles/20001274-chatgpt-voice
- Apple IOBluetooth: https://developer.apple.com/documentation/iobluetooth
- Apple CoreAudio: https://developer.apple.com/documentation/coreaudio
- BlackHole: https://github.com/ExistentialAudio/BlackHole
- PhoneBT: https://github.com/icoainc/phonebt
- HFPilot: https://github.com/maratsarbasov/HFPilot

### 已验证与未验证的边界

此项目的跨平台 Swift 核心单元测试已在 **Linux + Swift 6.2.1** 执行通过；由于当前执行环境不是 macOS，**没有真正编译、签名或运行 Apple 平台的 SwiftUI/IOBluetooth/CoreAudio 部分，也没有针对 vivo S9e 或 ChatGPT Voice 做实体测试**。下一步需在用户 Mac 上运行构建脚本及设备自检，并将脱敏 ZIP 回传排查平台兼容问题。
