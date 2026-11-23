# 电话接听与 AI 语音自动回复实施方案

更新时间：2026-11-23。现有目标设备：vivo S9e / Android 13 / 联通 SIM、Apple Silicon Mac、BlackHole 2ch 与 16ch、ChatGPT Plus 官方 Voice。不默认使用付费 API。

## 已实现部分（V0.4.8 代码，仍需真机验收）

- Android Companion V0.3.5 新增可选的系统 `ANSWER_PHONE_CALLS` 授权入口，**不修改默认拨号应用**；只在用户从 Mac 明确点击「人工接听当前来电」时，通过原有已认证 ADB loopback 的 `POST /call/answer` 请求接听。手机再次读取系统通话状态，只有 `CALL_STATE_RINGING` 才调用 `TelecomManager.acceptRingingCall()`。
- `TelecomManager.acceptRingingCall()` 已在 Android API 29 标记 deprecated，但 Android 13 仍保留该接口；真实 vivo 固件能否接听必须实际测试，拒绝时可使用 scrcpy 手动接听。回应 200 表示系统接听请求已发出，**不代表对方已经接通**；应等待 OFFHOOK。
- Mac V0.4.8 在已接通电话并主动启动实时 PCM 后，可手动开启「一键 GPT 双向语音」：电话下行 → BlackHole 2ch → 官方 ChatGPT Voice → BlackHole 16ch → 电话上行。用户需手动开启官方 Voice、指定设备、选择真实耳机并再次确认对方同意 AI 参与。任何一路初始化失败会撤销前面的路由；支持「立即停止 GPT 语音回传」。
- 使用现有 16kHz 单声道 PCM、20ms 帧和现阶段 180 秒单次音频限制，不假装具备全天无人值守能力。Android 电话事件只记录 RINGING/OFFHOOK/IDLE，不读取来电号码。
- 原来的飞书短信验证码转发继续独立运行；本次没有开启录音、转写、自动接听或把通话文本上传飞书。

## 如何用 ChatGPT Plus 实机验收双向通话

1. 手机 Companion 获取可选「接听电话」权限，并在 Mac 验证只有一台授权手机。首次授权只能通过手机系统弹窗或本人使用 scrcpy 手动点击。
2. 官方 ChatGPT 网页手动进入 Voice，麦克风选择 **BlackHole 2ch**，Voice 输出选择 **BlackHole 16ch**（无独立输出选项时按需手动调整 Mac 系统输出），耳机作为 SIM AI Assistant 单独监听设备；勿把 BlackHole16 的系统通知或其他音频误送入电话。
3. 从本人控制的另一号码拨打联通 SIM，Mac 按「人工接听当前来电」，确认系统从 RINGING 转 OFFHOOK。若 vivo 拒绝第三方接听，改用 scrcpy 按下接听，并导出脱敏错误诊断。
4. 先征得通话另一方对使用 ChatGPT 语音辅助的明确同意。启动「实时通话音频」，确认有非静音下行 PCM，再按「一键开启 GPT 双向电话」，让对方问一个非敏感问题，验证双方是否都听到正常语音。关闭 Mac 麦克风，避免串音。
5. 检查 AI 回复采集帧数、峰值 RMS、耳机播放丢帧、电话上行欠载；若任何指标异常或发生回声，立即停止路由。测试结束不上传原始语音、验证码或真实电话号码。

## 后续可以做什么，哪些不能用 Plus 完全自动

### A. 有人值守，一键接听与通话（本轮开始，建议先验收）

Mac 收到 RINGING 后展示接听按钮；用户点击；确定 OFFHOOK 后用户启动 PCM 和 GPT 路由，挂断后自动清理。增强方向：麦克风和音频路由硬件检查、语音会话已经手动准备好的状态提示、更准确的断线/重连、人工接管。**不在没有授权时自动打开通话声音。**

### B. 受控自动接听（后续需要额外开发与验收）

可以在用户显式打开「自动接听」且 Android 已授权 `ANSWER_PHONE_CALLS` 后，在响铃时判断允许时段、拨打来源规则、Mac 在线/音频引擎就绪状态、短延迟和人工随时取消。默认关闭；开机/断开 GPT Voice 时自动停用。首次接听还需要让对方知道 AI 在通话，避免隐瞒身份。

但目前 Android Companion **不采集来电号码**，因此不具备号码白名单能力；如以后加入，需另外取得适当权限并设计最小化存储。也可能受 vivo 系统限制。不要悄悄更改默认电话 App。

### C. 真正全天候无人值守的 GPT 接线员

ChatGPT Plus 的官方 Voice 是终端用户交互功能，**不是**可供 SIM AI Assistant 静默启动/控制的实时语音 API。即便实现了 Android 自动接听，也不能保证程序能无人值守地创建、重连或维护官方 ChatGPT Voice 会话。页面或声音设备设置随产品更新会变化，不应依赖未授权接口或模拟 OAuth Cookie。

要稳定实现“来电即自动接听 → AI 自动开场 → 多轮语音交互 → 自动挂机 → 摘要/飞书”，应另设计可编程的实时语音模型/ASR+TTS 服务，通常涉及 API 调用和费用；也可验证完整本地模型方案的时延与资源占用。此方案单独立项，不等于 Plus 订阅权益。

## 风险、权限及边界

- Android 官方 `TelecomManager.acceptRingingCall()` 在 Android 10（API 29）被标记为 deprecated；需要 `ANSWER_PHONE_CALLS`，vivo 可能拒绝该调用：https://developer.android.com/reference/android/telecom/TelecomManager
- 官方 Voice 文档：https://help.openai.com/en/articles/20001274-chatgpt-voice
- 通话音频经第三方服务处理前，应获得参与者知情同意并遵守当地适用法规。Mac 用户必须能立即停止 GPT 上行；默认不转发 GPT/其他系统应用声音。
- 若系统默认输出指向 BlackHole 16ch，所有进入该设备的声音都可能进入运营商通话；需禁用通知声及无关程序声音。
- Android API 返回的答应接听请求不等于实际接听成功。对所有失败情况保留分类诊断；不要记电话号、Token、密钥或通话内容。
- 不接入自动挂断/强制结束其它电话、不私自申请默认拨号角色、不后台偷偷更改系统权限、不绕过操作系统限制。

## APK 签名迁移

新签名必须匹配以后安装包。当前 GitHub 连接没有仓库 Actions Secrets 写入能力，因此不能直接代用户上传私钥。已附带 `Scripts/setup-android-signing.sh`：用户在自己的受信任 Mac 上运行一次，输入由自己保存的密码，脚本生成或复用私有证书并通过 `gh secret set`（登录用户具备仓库管理员权限）设置四项 Secrets。私钥不发送到聊天/公共仓库。

即使配置完成，如果已安装的旧 Debug APK 是另一证书签的，Android 也不能直接无损覆盖；需要在原有设置安全备份后，经用户确认完成一次迁移。脚本本身不卸载手机 App。
