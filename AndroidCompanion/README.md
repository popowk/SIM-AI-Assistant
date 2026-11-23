# SIM AI Companion — Android 0.3.5 测试版

## V0.3.5 · Mac 人工接听当前来电

- 手机 Companion 新增可选接听权限按钮，用户明确知情后才向 Android 系统请求 ANSWER_PHONE_CALLS。
- 原有私有令牌认证回环端点增加 `POST /call/answer`，只接受空请求体；即使 Mac 状态为 RINGING，也会重新查询 Android 电话系统当前是否仍响铃。调用系统 `TelecomManager.acceptRingingCall()` 只代表向系统请求，不等于接听必然成功。
- 接口已 deprecated，Android 13 的 vivo 固件能否接受第三方接听需实机验证。失败可以使用 Mac 的 scrcpy 手机镜像窗口人工接听。没有新增自动接听、自动挂断、默认拨号角色、原始电话音频录制或号码读取。
- Mac V0.4.8 提供双向 Voice 的人工确认一键联动和立即停止；Voice 仍需用户在官方界面手动打开。

## V0.3.4 · 固定签名可选（先完成仓库私钥配置）

- Gradle Debug APK 在同时提供 keystore 路径、口令、alias、私钥口令时使用相同的开发者证书签名；GitHub Actions 从加密的 Repository Secrets 获取材料，安全地编译并删除临时文件。仍为 debug APK，保留 ADB run-as 机制。
- **尚未配置 Secrets 的 GitHub Runner 仍使用临时 debug 签名**，并在 Mac 安装面板提醒不保证无损覆盖；已有旧证书找不到时可能需要最后一次手动确认的签名迁移，绝不自动卸载。
- 详见根目录 docs/ANDROID_SIGNING_MIGRATION.md。版本码 9，Android Companion V0.3.4，Mac V0.4.6 Build 23。SMS 转发/电话权限行为不变。

## V0.3.0 · 飞书短信 Webhook 通知（默认开启开关）

- 适用于手机自身新收到的短信（包括运营商验证码）；**完整正文按原样保留**，在前面标注发送方和“短信全文”。多段短信通过系统提供的 PDU 列表合并，无需 READ_SMS，也不读取收件箱历史。
- 默认勾选“自动转发新短信”；但 **只有用户在 Android 系统权限弹窗授权 RECEIVE_SMS，并在手机 App 本地保存有效的飞书自定义机器人 HTTPS Webhook，才实际发送**。只依赖 vivo S9e 的网络，不依赖 Mac/ADB/电话监听服务。
- 仅允许 `https://open.feishu.cn/open-apis/bot/v2/hook/...` 或 `https://open.larksuite.com/open-apis/bot/v2/hook/...`，不允许 HTTP、其他主机或重定向。
- 使用飞书机器人 `msg_type: text` 格式；可填写飞书签名校验密钥（可选）。若开启签名校验，消息包含时间戳与 HMAC-SHA256 签名。
- Android App 界面提供：默认开启的开关、请求短信权限、Webhook/签名输入与保存、发送不含验证码的测试消息、清除配置、匿名发送状态。Webhook 地址与签名只保存在 App 私有首选项，不进入诊断日志；短信正文/验证码仅在接收后于内存中构造发送，不写入磁盘。
- 简单去重以避免一条系统广播的重复投递；连接/读取各 4 秒超时，发送失败记录类别，不会持久保存或离线排队原文。因此断网时 **不能保证短信补发**，Android 电池管理与部分 SMS Retriever 专属消息也可能受系统限制。
- 飞书群成员能够查看短信全文与验证码，请务必使用自己控制的**私人飞书群**，只授权必要人员；收到验证码应及时使用，群消息可能被飞书平台保存。不得将此权限用于读取非本人设备或非本人有权访问的短信。
- 软件不请求 READ_SMS/SEND_SMS，不自动发送手机短信，不允许远程修改 Webhook。首次升级 Android Companion 到 V0.3.0 需要用户手动确认 RECEIVE_SMS 运行时权限；此前的电话状态功能保持独立。
- **Android 限制**：RECEIVE_SMS 属于系统 hard-restricted 权限，只有安装程序已允许该权限时才能真正授予。若手机上权限弹窗无法授权，不会尝试绕过系统限制；请检查合法安装来源及系统权限。Android 13 的 vivo 实机可用性必须以授权结果与新短信测试验证。
- 注意 Android Debug APK 不同 GitHub Runner 可能使用不同临时签名：`adb install -r` 失败时**不会自动卸载**；用户如主动卸载重装会清除应用私有设置、电话监听授权和桥接令牌，需重新授权、重配。优先保留旧数据，不要为本功能盲目清空。

## 功能
- 由用户主动启动/停止本机电话状态监听服务，展示 IDLE/RINGING/OFFHOOK。
- READ_PHONE_STATE 明确运行时授权，不采集来电号码、联系人、IMEI、通话录音；V0.3.0 新增用户配置的入站短信转发（正文不写入日志）。
- Android 12+ 使用 TelephonyCallback.CallStateListener，Android 8–11 使用 PhoneStateListener。
- 前台服务通知显示运行状态，拒绝权限时不能运行，关闭 App 不代表手动停止服务。
- 数据仅在手机本机显示；新版本添加本机只读电话状态 HTTP 服务，Mac 通过 USB ADB forward 接收事件（不使用局域网）。
- 不监听音频、不控制电话，不需要 root、HFP 或服务器。

## 构建
`gradle -p AndroidCompanion :app:assembleDebug`（JDK 17 + Android SDK 35 + Gradle 8.9）。
APK 默认通过 Android SDK 的临时 debug 签名生成。**同一 APK 重复安装可使用 adb install -r，但跨 CI 构建若 debug 签名证书变化，系统会拒绝覆盖。** 不会自动卸载或删除手机应用数据。要实现跨版本无损覆盖，需要配置稳定且安全保存的 Android 签名密钥，不能把私钥公开提交到仓库。

## 使用
通过 Mac App 选择本机 ADB 路径，使用 USB 授权单台 Android 手机后点击「安装/覆盖 APK」。成功后手机上打开 SIM AI Companion，主动允许「电话状态」权限，并点击「启动电话状态监听」。用另一台手机拨号测试；观察 RINGING/OFFHOOK/IDLE 状态更新。不要将 API 监听结果与实际电话音频获取混淆。

注意 vivo 省电/后台限制可能终止服务；先允许 App 的正常后台运行并保持屏幕亮起进行初次实验。


## 0.2.0 USB 事件通道

- 安卓监听服务运行时在 127.0.0.1:18764 提供只读 `/events?since=N`。
- 私有文件 `files/bridge-token` 存放每次安装随机生成的 32 字节令牌，Mac 通过已授权设备的 debug `run-as` 读取，不写入日志。
- 事件字段：`schema/session/running/state/seq/events[{seq,state,at}]`，不传号码、联系人、设备 ID 或电话音频。
- Mac 建立 `adb forward tcp:0 tcp:18764`，自动轮询、去重和恢复。
- 只有 debug APK 支持 run-as。签名不同无法覆盖时，使用 Mac 端**需明确确认**的重装选项，会清空此 APK 自己的私有数据。


## V0.2.1 锁屏监听可用性增强

App 需要用户明确启动电话状态监听，才在本机 127.0.0.1 接收已经授权的 Mac ADB 转发请求。

- 状态 HTTP 端点处理改为 2 个请求线程 + 有界排队，避免单个请求长时间占用监听循环。
- 前台服务有条件地允许系统重启（START_STICKY）。
- 「锁屏运行增强」是**默认关闭**的可选项，使用 PARTIAL_WAKE_LOCK 维持 CPU 活动，明显可能增加电耗。禁用或停止监听后释放。它不会重新开启无线调试、解除系统授权或保证绕过省电限制。
- 通过「打开本应用系统设置」进入 vivo 的后台/电池管理，允许后台运行等操作需要用户自行确认。
- 打包版本为 0.2.1 (versionCode 3)。旧版的 CI debug 签名可能不同；不要悄悄卸载造成数据和权限损失。


## V0.2.2 HTTP 超时后的私有快照备用

监听服务在私有 `files/bridge-snapshot.json` 中存放匿名状态（非号码、非音频），采用 AtomicFile 进行原子保存，每 15 秒刷新存活标记。Mac 只有通过已授权的 ADB debug `run-as` 才能读取，超过 90 秒或服务停止的快照不作为在线状态。版本 0.2.2（versionCode 4）。
