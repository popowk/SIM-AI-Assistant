# Android Audio Helper

Android 13+ 电话音频兼容性检测与双向 PCM 服务，共用于 USB ADB 和 Shizuku 音频方案。

- info：检测电话音频 API、系统模式及设备能力。
- downlink：已接通且授权的电话下行声音电平检测。
- uplink：已接通且授权的电话上行测试音。
- serve：通过 ADB 回环端口建立 16 kHz 单声道 PCM16 全双工通道。
- serveConnected：供已授权的 Shizuku UserService 使用的共享音频实现。

实际采集和注入受 Android 系统及厂商限制。单次音频服务上限 180 秒，不在 Helper 内保存录音或通话内容。

第三方参考与授权信息见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
