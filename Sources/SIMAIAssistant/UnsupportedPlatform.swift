#if !os(macOS)
import Foundation
@main struct UnsupportedPlatform {
    static func main() {
        print("SIM AI Assistant 的界面需要 macOS 13+。此 Linux 构建仅用于编译核心逻辑与运行单元测试。")
    }
}
#endif
