import Foundation
import RemoteRustDesk

/// RustDesk 的日志夹具：取自 2026-11-20 本机 `~/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log` 的真实一次会话，
/// 控制端地址已换成文档保留地址；1.5.3 那份是按新版格式串补的形状样本（少了 width=），见文件头
enum RustDeskFixtures {
    static func lines(_ name: String) throws -> [String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "log", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
    }

    /// 逐行解析、折叠成一拍一拍的状态
    static func replay(_ name: String) throws -> [RustDeskSignals] {
        var state = RustDeskSessionState()
        // 第一拍是「一行都还没读」：空状态，方便断言「连入之前不在场」
        var out: [RustDeskSignals] = [state.signals]
        for line in try lines(name) {
            if let event = RustDeskLogParser.parse(line) { state.apply(event) }
            out.append(state.signals)
        }
        return out
    }
}
