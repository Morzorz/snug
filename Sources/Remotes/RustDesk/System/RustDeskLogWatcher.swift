// 连接与推流信号：跟随 RustDesk 自己写的日志文件（`--server` 那份）。只读文件、不起子进程：
// 从哪儿读、要不要重来由 RustDeskLogAnchor 算（纯逻辑、有测试），这里只管读文件、切行、喂解析器。
// 日志读不到（没装、没在运行、没权限）时交 readable=false 的观测，连接判定不当成在场
import Foundation
import RemoteRustDesk
import SnugCore

@MainActor
final class RustDeskLogWatcher {
    /// 首次读整个文件最多读这么多，再大就从尾部截（日志按天轮转，正常远小于它）
    static let replayLimit: UInt64 = 4 * 1024 * 1024

    private let url: URL
    private var anchor = RustDeskLogAnchor()
    /// 半行攒在这里：一行常被切在两次读之间
    private var cursor = RustDeskLogCursor()
    private(set) var state = RustDeskSessionState()
    private(set) var readable = false
    private(set) var lineCount = 0
    /// 读不到只记一次日志：每拍都记会把 Snug.log 刷满
    private var reportedMissing = false
    /// 已经读过一次：之后的 reset 才是「换了文件」，第一次不算
    private var readOnce = false

    init(url: URL = RustDeskLogWatcher.standardURL) {
        self.url = url
    }

    static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RustDesk/server/RustDesk_rCURRENT.log")
    }

    var path: String { url.path }

    /// 开始监控：从头读。远程中途打开 Snug（升级、崩溃后自启）时，正在进行的会话就在这个文件里
    func start() {
        anchor = RustDeskLogAnchor()
        cursor.dropPending()
        state = RustDeskSessionState()
        lineCount = 0
        readable = false
        reportedMissing = false
        readOnce = false
    }

    /// 每拍读一次新增的部分
    func sample() -> RustDeskSignals {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            unavailable("RustDesk 的日志不在（\(path)）：没装、没在运行，或换了日志目录")
            return RustDeskSignals(readable: false)
        }
        let plan = anchor.plan(fileID: inode, size: size, replayLimit: Self.replayLimit)
        if plan.reset {
            // 换了文件（RustDesk 重启）或清空了：之前的连接与推流作废
            if readOnce { Log.info("RustDesk 的日志换了文件（\(path)），连接与推流状态重来") }
            cursor.dropPending()
            state = RustDeskSessionState()
            lineCount = 0
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: plan.start)
            let data = try handle.readToEnd() ?? Data()
            anchor.consumed(UInt64(data.count))
            let lines = cursor.feed(plan.skipPartialLine ? droppingPartialLine(data) : data)
            for line in lines {
                lineCount += 1
                if let event = RustDeskLogParser.parse(line) { state.apply(event) }
            }
            readable = true
            reportedMissing = false
            readOnce = true
        } catch {
            unavailable("读不了 RustDesk 的日志（\(path)）：\(error.localizedDescription)")
            return RustDeskSignals(readable: false)
        }
        return state.signals
    }

    /// 截读的起点落在行中间：丢到第一个换行之后
    private func droppingPartialLine(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return data[data.index(after: newline)...]
    }

    private func unavailable(_ message: String) {
        readable = false
        guard !reportedMissing else { return }
        reportedMissing = true
        Log.warn(message)
    }
}
