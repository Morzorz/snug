// 解析 RustDesk 自己写在 ~/Library/Logs/RustDesk/ 里的日志行（--server 一份、每次 --cm 一份）。
// 这些行不是公开接口，只认几条带稳定措辞的，认不出的行一律忽略；措辞变了，自检（RustDeskCheck）会报出来。
// 行形如：[2026-11-20 10:07:36.517379 +08:00] DEBUG [src/server/connection.rs:1455] #642 Connection opened from 100.81.16.29:63452.
import Foundation
import SnugCore

package enum RustDeskLogEvent: Equatable, Sendable {
    /// 一个控制端连上来。peer 是日志里的「地址:端口」：RustDesk 不写控制端的设备名
    case opened(conn: Int, peer: String)
    /// 这个连接结束（对端关闭、超时、被挤下去都算）
    case closed(conn: Int)
    /// 推流用的屏：monitor 是 RustDesk 的下标，id 是 CGDirectDisplayID（日志里写作 name:<id>）
    case display(monitor: Int, id: DisplayID)
    /// 开始为某块屏推流；换屏时新开一路，旧的那路随后停
    case videoStarted(monitor: Int)
    case videoStopped(monitor: Int)
}

package enum RustDeskLogParser {
    /// 一行 → 事件；认不出返回 nil。
    /// 推流屏那行只认 `current=` 与 `name:`，中间当自由文本：1.4.9 有 `width=`、1.5.3 去掉了，位置也会变
    package static func parse(_ line: String) -> RustDeskLogEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let event = connection(text) { return event }
        if let event = display(text) { return event }
        if let start = text.range(of: "new video service: monitor") {
            return Int(text[start.upperBound...].prefix(while: \.isNumber)).map { .videoStarted(monitor: $0) }
        }
        if let stop = text.range(of: "stop video service: monitor") {
            return Int(text[stop.upperBound...].prefix(while: \.isNumber)).map { .videoStopped(monitor: $0) }
        }
        return nil
    }

    /// 行首的时间戳（`[2026-11-20 10:07:36.517379 +08:00]`）；认不出为 nil。自检按它截取时间范围
    package static func stamp(_ line: String) -> Date? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let text = line[line.index(after: line.startIndex)..<close]
        let parts = text.split(separator: " ")
        guard parts.count == 3,
              let zone = timeZone(parts[2]),
              let date = stampFormatter(zone).date(from: String(parts[0]) + " " + parts[1].prefix(while: { $0 != "." }))
        else { return nil }
        return date
    }

    private static func connection(_ text: String) -> RustDeskLogEvent? {
        for (marker, isOpen) in [(" Connection opened from ", true), (" Connection closed: ", false)] {
            guard let mark = text.range(of: marker) else { continue }
            guard let hash = text[..<mark.lowerBound].lastIndex(of: "#"),
                  let conn = Int(text[text.index(after: hash)..<mark.lowerBound].prefix(while: \.isNumber)) else { return nil }
            guard isOpen else { return .closed(conn: conn) }
            var peer = String(text[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
            if peer.hasSuffix(".") { peer.removeLast() }
            return peer.isEmpty ? nil : .opened(conn: conn, peer: peer)
        }
        return nil
    }

    /// `#displays=2, current=0, origin: (0, 0), [width=3024, ]height=1964, cpus=14/14, name:1`
    private static func display(_ text: String) -> RustDeskLogEvent? {
        guard let start = text.range(of: "#displays=")?.upperBound,
              let current = text[start...].range(of: "current="),
              let monitor = Int(text[current.upperBound...].prefix(while: \.isNumber)),
              let name = text.range(of: "name:", range: current.upperBound..<text.endIndex),
              let id = DisplayID(text[name.upperBound...].prefix(while: \.isNumber)) else { return nil }
        return .display(monitor: monitor, id: id)
    }

    /// `+08:00` → 时区；认不出为 nil
    private static func timeZone(_ offset: Substring) -> TimeZone? {
        guard let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let clock = offset.dropFirst().split(separator: ":")
        guard clock.count == 2, let hours = Int(clock[0]), let minutes = Int(clock[1]) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    private static func stampFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = zone
        return formatter
    }
}

/// 把一块块数据切成完整的行：一行常被切在两块里（读了半行又来半行），按字节攒到换行再解码（先解码会把切在中间的汉字解坏）。
/// 起点落在行中间时（从文件中部截读）先丢掉那半行：`dropPending`
package struct RustDeskLogCursor {
    private var pending = Data()

    package init() {}

    /// 追加一块数据，交出其中完整的行（不含换行）；末尾那半行留着等下一块
    package mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// 丢掉攒着的半行（截读、换文件、清空之后调用）
    package mutating func dropPending() {
        pending.removeAll()
    }

    package var pendingBytes: Int { pending.count }
}

/// 跟随一个会被轮转、清空、替换的日志文件：按文件现在的样子算出这次从哪儿读。
/// RustDesk 每次启动写一份新的 CURRENT，按天轮转，所以「文件换了」「文件变短了」都要从头再算
package struct RustDeskLogAnchor: Equatable, Sendable {
    package private(set) var offset: UInt64 = 0
    package private(set) var fileID: UInt64?

    package init() {}

    package mutating func plan(fileID: UInt64, size: UInt64, replayLimit: UInt64) -> RustDeskLogPlan {
        var reset = false
        if self.fileID != fileID || size < offset {
            reset = true
            offset = 0
        }
        self.fileID = fileID
        var start = offset
        var skipPartialLine = false
        if start == 0, size > replayLimit {
            // 整份太大：只读尾部。头一段落在行中间，调用方要丢到第一个换行之后
            start = size - replayLimit
            skipPartialLine = true
        }
        return RustDeskLogPlan(reset: reset, start: start, skipPartialLine: skipPartialLine)
    }

    /// 这次真的读到了这么多字节
    package mutating func consumed(_ bytes: UInt64) {
        offset += bytes
    }
}

package struct RustDeskLogPlan: Equatable, Sendable {
    /// 状态要从头算：第一次读、文件换了、文件被清空
    package var reset: Bool
    /// 从哪个字节开始读
    package var start: UInt64
    /// 起点落在行中间，头一段是半行
    package var skipPartialLine: Bool
}
