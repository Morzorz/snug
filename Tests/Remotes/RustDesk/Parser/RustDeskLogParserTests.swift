import Foundation
import SnugCore
import Testing
@testable import RemoteRustDesk

@Suite("RustDesk 日志解析")
struct RustDeskLogParserTests {
    @Test("连入行：带连接号和控制端地址，行尾的句点去掉")
    func opened() {
        let line = "[2026-11-20 10:07:36.517379 +08:00] DEBUG [src/server/connection.rs:1455] #642 Connection opened from 203.0.113.7:63452."
        #expect(RustDeskLogParser.parse(line) == .opened(conn: 642, peer: "203.0.113.7:63452"))
    }

    @Test("断开行：断开原因是自由文本，只取连接号")
    func closed() {
        #expect(RustDeskLogParser.parse("[x] INFO [src/server/connection.rs:5146] #642 Connection closed: Peer close") == .closed(conn: 642))
        #expect(RustDeskLogParser.parse("[x] INFO [src/server/connection.rs:5146] #7 Connection closed: Reset by the peer")
            == .closed(conn: 7))
    }

    @Test("推流屏：取 current 与 name:（name 就是 CGDirectDisplayID）；中间字段多一个少一个都不影响")
    func display() {
        let old = "[x] DEBUG [src/server/video_service.rs:426] #displays=2, current=0, origin: (0, 0), width=3024, height=1964, cpus=14/14, name:1"
        // 1.4.9 与 1.5.3 实测都带 width=；这里另钉一种不带它的写法，免得哪天字段加减就认不出
        let variant = "[x] DEBUG [src/server/video_service.rs:426] #displays=1, current=0, origin: (0, 0), height=1964, cpus=14/14, name:1"
        #expect(RustDeskLogParser.parse(old) == .display(monitor: 0, id: 1))
        #expect(RustDeskLogParser.parse(variant) == .display(monitor: 0, id: 1))
        let second = "[x] DEBUG [src/server/video_service.rs:426] #displays=2, current=1, origin: (1512, -35), width=1920, "
            + "height=1080, cpus=14/14, name:3"
        #expect(RustDeskLogParser.parse(second) == .display(monitor: 1, id: 3))
    }

    @Test("推流开始与停止：monitor 下标是 RustDesk 自己的顺序")
    func videoServices() {
        #expect(RustDeskLogParser.parse("[x] INFO [src/server/video_service.rs:909] new video service: monitor0") == .videoStarted(monitor: 0))
        #expect(RustDeskLogParser.parse("[x] DEBUG [src/server/video_service.rs:304] Create capturer from scrap") == nil)
        #expect(RustDeskLogParser.parse("[x] INFO [src/server/video_service.rs:921] stop video service: monitor1") == .videoStopped(monitor: 1))
    }

    @Test("别的行一律不认：日志里还有大量与连接无关的行")
    func noise() {
        for line in [
            "[x] INFO [src/server/connection.rs:2063] peer info supported_encoding: SupportedEncoding { h264: false }",
            "[x] INFO [src/server/display_service.rs:387] Displays changed",
            "[x] INFO [libs/enigo/src/macos/macos_impl.rs:179] double click interval: 500ms",
            "[x] WARN [src/common.rs:1384] TCP proxy fallback also failed: TCP proxy connection closed without response",
            "", "不是日志",
        ] {
            #expect(RustDeskLogParser.parse(line) == nil, "\(line)")
        }
    }

    @Test("时间戳：读回行首那一刻，时区按行里的偏移算")
    func stamp() throws {
        let date = try #require(RustDeskLogParser.stamp("[2026-11-20 10:07:36.517379 +08:00] DEBUG [x] y"))
        let utc = try #require(ISO8601DateFormatter().date(from: "2026-11-20T02:07:36Z"))
        #expect(abs(date.timeIntervalSince(utc)) < 1)
        #expect(RustDeskLogParser.stamp("没有时间戳") == nil)
    }

    @Test("真实的 1.4.9 会话：连入、换屏、断开、停流按顺序折叠出来")
    func realSession() throws {
        let signals = try RustDeskFixtures.replay("server-session-1.4.9")
        #expect(signals.count == 14)
        // 连入前：不在场
        #expect(!signals[0].isPresent)
        // 连入后：在场，控制端是日志里的地址:端口，还没有推流
        #expect(signals[1].isPresent)
        #expect(signals[1].peers == ["203.0.113.7:63452"])
        // 推流开始 + 屏描述之后：认得出推的是 #1
        let started = try #require(signals.firstIndex { $0.streamedDisplay != nil })
        #expect(signals[started].streamedDisplay == 1)
        #expect(signals[started].monitor == 0)
        // 换屏：monitor1 起、monitor0 停，推流屏变成 #3
        let switched = try #require(signals.lastIndex { $0.streamedDisplay == 3 })
        #expect(signals[switched].monitor == 1)
        // 断开后：不在场，推流屏也不留
        let lastOpen = try #require(signals.lastIndex { !$0.peers.isEmpty })
        #expect(signals[(lastOpen + 1)...].allSatisfy { !$0.isPresent && $0.streamedDisplay == nil && $0.monitor == nil })
    }

    @Test("真实的 1.5.3 会话（两次换屏）：推流屏 1 → 3 → 1，断开后不在场")
    func session153() throws {
        let signals = try RustDeskFixtures.replay("server-session-1.5.3")
        let seen = signals.compactMap { $0.streamedDisplay }
        // 第一次换到 monitor1（#3），又切回 monitor0（#1）
        #expect(seen.first == 1)
        #expect(seen.contains(3))
        #expect(try #require(seen.last) == 1)
        #expect(signals.contains { $0.monitor == 1 && $0.streamedDisplay == 3 })
        #expect(signals.last?.isPresent == false)
    }

    @Test("按字节切行：一行切在两块里、一块里有多行、结尾半行等下一块")
    func cursor() {
        var cursor = RustDeskLogCursor()
        #expect(cursor.feed(Data("a\nb".utf8)) == ["a"])
        #expect(cursor.pendingBytes == 1)
        #expect(cursor.feed(Data("c\n\n".utf8)) == ["bc", ""])
        #expect(cursor.pendingBytes == 0)
        // 汉字切在中间：按字节攒，解出来不坏
        let line = Data("「甲」\n".utf8)
        #expect(cursor.feed(line.prefix(2)) == [])
        #expect(cursor.feed(line.dropFirst(2)) == ["「甲」"])
        // 截读时丢掉开头的半行
        cursor.dropPending()
        #expect(cursor.feed(Data("半行".utf8)) == [])
        cursor.dropPending()
        #expect(cursor.feed(Data("整行\n".utf8)) == ["整行"])
    }

    @Test("跟随日志文件：第一次从头读、之后只读新增；换文件或变短就重来；整份太大只读尾部并丢掉半行")
    func anchor() {
        var anchor = RustDeskLogAnchor()
        #expect(anchor.plan(fileID: 1, size: 100, replayLimit: 1000) == RustDeskLogPlan(reset: true, start: 0, skipPartialLine: false))
        var current = anchor.plan(fileID: 1, size: 100, replayLimit: 1000)
        anchor.consumed(100)
        // 文件长了：只读新增的那一段
        current = anchor.plan(fileID: 1, size: 160, replayLimit: 1000)
        #expect(current == RustDeskLogPlan(reset: false, start: 100, skipPartialLine: false))
        anchor.consumed(60)
        // 换文件（RustDesk 重启）：从头再来
        #expect(anchor.plan(fileID: 2, size: 30, replayLimit: 1000) == RustDeskLogPlan(reset: true, start: 0, skipPartialLine: false))
        // 变短（清空）：从头再来
        var cleared = RustDeskLogAnchor()
        _ = cleared.plan(fileID: 3, size: 100, replayLimit: 1000)
        cleared.consumed(100)
        #expect(cleared.plan(fileID: 3, size: 10, replayLimit: 1000) == RustDeskLogPlan(reset: true, start: 0, skipPartialLine: false))
        // 整份太大：只读尾部，头一段要当半行丢掉
        var huge = RustDeskLogAnchor()
        #expect(huge.plan(fileID: 4, size: 1000, replayLimit: 400) == RustDeskLogPlan(reset: true, start: 600, skipPartialLine: true))
    }
}
