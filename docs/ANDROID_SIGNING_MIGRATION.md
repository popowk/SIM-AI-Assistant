# Android Companion 固定签名与无损升级迁移说明

版本：Mac V0.4.6 Build 23 / Android Companion V0.3.4 (versionCode 9)

## 本次代码已实现

- `AndroidCompanion/app/build.gradle.kts` 在 4 项环境变量全部存在时，为 Debug APK 使用固定开发者签名（仍保持 debuggable，以支持 ADB `run-as` 私有配置同步）。
- GitHub Actions 从**仓库 Secrets** 读取 Base64 keystore 和口令，临时存放在 Runner 的受限临时文件，编译后删除；不公开签名私钥、口令或手机的飞书配置。
- Secrets 全缺省时构建仍可运行，但标记 `EPHEMERAL_DEBUG_SIGNING`，即 **不保证能覆盖升级之前安装的 APK**。任何只配置一部分的状态均直接失败，不会悄悄换证书。
- `SIMAI-Android-Signing.txt` 和 Mac 的「Android 安装区域」显示固定/临时签名状态；`adb install -r` 失败不会自动卸载。无损升级要求安装前后签名兼容。

## 需要仓库管理员一次性准备（不能由公开 CI 自动发明私钥）

在你信任且受控的本地 Mac 上创建并离线备份 Android 签名 keystore（只做一次；后续升级必须使用同一证书）。**如果旧签名 keystore 仍然可找到，请优先复用旧签名，不要生成新证书。**

可以使用 JDK 17 的 `keytool -genkeypair -keystore ~/simai-companion-private.jks -storetype PKCS12 -alias simai-companion -keyalg RSA -keysize 3072 -validity 36500`，按交互提示输入并妥善保存密码、备份 keystore。不能把它提交到 GitHub 代码仓库、公开日志、诊断 ZIP 或聊天。

在 GitHub 仓库 **Settings → Secrets and variables → Actions** 中配置四项仓库 Secret：

| 名称 | 用途 |
|---|---|
| `SIMAI_ANDROID_KEYSTORE_B64` | 完整 keystore 文件的 Base64，编码过程在本地执行；不要直接上传文件到仓库 |
| `SIMAI_ANDROID_KEYSTORE_PASSWORD` | Keystore 口令 |
| `SIMAI_ANDROID_KEY_ALIAS` | 证书 alias |
| `SIMAI_ANDROID_KEY_PASSWORD` | 私钥口令（若与 keystore 口令相同也须配置） |

完成后在 GitHub Actions 手动触发新构建，下载新 APK。新版 Mac 安装面板应显示 **固定签名构建**，发布文件 `SIMAI-Android-Signing.txt` 为 `STABLE_SECRET_SIGNING`。不配置上述 Secrets 时，新包仍为临时签名，仅适合研发。

## 迁移限制和安全升级

Android 核验新旧 APK 签名。**如果手机中当前 V0.3.3 安装包是旧 CI Runner 随机 debug key 签的，且旧密钥无法找回，不能靠新密钥直接无损覆盖。** Android 更新失败会保护旧数据。此时应先在现有手机和 Mac 备份用户可合法备份的配置/核对钥匙串，做好最终一次受控的重新授权与迁移，再切换固定签名；不能声称换证书后无需重装。

不要利用 `adb uninstall` 自动排错、跳过系统权限或对手机设备序列号进行模糊匹配。清空数据的「签名不一致？确认清空后重装」入口必须保持二次确认。完成迁移后只用同一 keystore 对所有未来 APK 进行签名，版本码单调递增，再执行 `adb install -r` 安装并验证短信权限、飞书发送、电话监听和私有 ADB 配置同步。

## 下一步未实现

- 新密钥保存到 GitHub Secrets 之前**并未解决实际固定签名**。这一点由 Mac 安装面板的状态直接反映。
- 正式可发布的 Android 非 debug / 非 `run-as` 版本需要重构认证配置接口，不能直接将当前 Debug APK 切换 `release` 并期待 ADB `run-as` 正常。
- 签名迁移完成后，再逐步增加网络发送队列、后台稳定性及 24 小时回归测试。
