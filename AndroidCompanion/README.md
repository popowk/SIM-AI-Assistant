# SIM AI Companion — Android 0.2.2 测试版

## 功能
- 由用户主动启动/停止本机电话状态监听服务，展示 IDLE/RINGING/OFFHOOK。
- READ_PHONE_STATE 明确运行时授权，不采集电话号码、联系人、IMEI、短信、录音。
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
