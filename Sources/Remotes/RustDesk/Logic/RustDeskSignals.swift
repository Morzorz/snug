// 一拍里对 RustDesk 的观测：从日志折叠出来的连接、控制端、推流屏，以及交给核心的中性观测。
// 只认正面证据：有连接（写进日志的连入行），或有一路推流还开着（日志级别被调高、认不出连入行时仍亮着）。
// 读不到日志（没装、没在运行、没权限）时 readable 为假，其余字段无意义，绝不算在场
import Foundation
import SnugCore

package struct RustDeskSignals: Equatable, Sendable, CustomStringConvertible {
    /// 日志读得到吗
    package var readable: Bool
    /// 此刻连着的控制端（日志里的「地址:端口」），按连入顺序
    package var peers: [String]
    /// 此刻在推的屏
    package var streamedDisplay: DisplayID?
    /// 正在推的是 RustDesk 的第几路（日志里叫 monitorN），写进快照
    package var monitor: Int?

    package init(readable: Bool = true, peers: [String] = [], streamedDisplay: DisplayID? = nil, monitor: Int? = nil) {
        self.readable = readable
        self.peers = peers
        self.streamedDisplay = streamedDisplay
        self.monitor = monitor
    }

    package var isPresent: Bool { readable && (!peers.isEmpty || monitor != nil) }

    /// 交给核心的中性观测。信号快照就是 description，写进连入、断开日志
    package func observation() -> RemoteObservation {
        RemoteObservation(present: isPresent, controllers: peers, streamedDisplay: streamedDisplay, evidence: description)
    }

    package var description: String {
        guard readable else { return "日志=读不到" }
        let peer = peers.last ?? "未识别"
        let display = streamedDisplay.map(String.init) ?? "未知"
        let video = monitor.map { "monitor\($0)" } ?? "否"
        return "peer=\(peer) display=\(display) video=\(video)"
    }

    /// 从日志里的信号快照（description 的写法）读回三样，自检用；写法对不上时为 nil。
    /// 读不到日志的那种（「日志=读不到」）也返回 nil：它不是一次观测，自检另算
    package static func logged(_ evidence: String) -> (peer: String?, display: DisplayID?, video: String?)? {
        guard let peer = field("peer=", in: evidence), let display = field("display=", in: evidence),
              let video = field("video=", in: evidence) else { return nil }
        return (peer == "未识别" ? nil : peer, display == "未知" ? nil : DisplayID(display), video)
    }

    /// 「key=值」里的值，到空格为止
    private static func field(_ key: String, in text: String) -> String? {
        guard let start = text.range(of: key)?.upperBound else { return nil }
        return String(text[start...].prefix { $0 != " " })
    }
}

/// 把日志事件折叠成此刻的状态：谁连着、在推哪块屏。纯值类型，时间不参与（RustDesk 的日志事件自带先后）
package struct RustDeskSessionState: Equatable, Sendable {
    private var connections: [RustDeskConnection] = []
    /// RustDesk 的 monitor 下标 → 屏编号：`new video service: monitorN` 后面紧跟一行 `#displays=… name:<id>`
    private var displaysOfMonitor: [Int: DisplayID] = [:]
    private var monitor: Int?

    package init() {}

    package mutating func apply(_ event: RustDeskLogEvent) {
        switch event {
        case .opened(let conn, let peer):
            if let i = connections.firstIndex(where: { $0.conn == conn }) { connections[i].peer = peer } else {
                connections.append(RustDeskConnection(conn: conn, peer: peer))
            }
        case .closed(let conn):
            // 认得出连入行时，最后一个连接断开就把推流一起清掉：停流的那行万一漏了，不能一直算在场。
            // 认不出连入行（日志级别调高）时 connections 本来就是空的，这里不动推流那一路
            let known = connections.contains { $0.conn == conn }
            connections.removeAll { $0.conn == conn }
            if known, connections.isEmpty { monitor = nil }
        case .display(let monitor, let id):
            displaysOfMonitor[monitor] = id
        case .videoStarted(let monitor):
            self.monitor = monitor
        case .videoStopped(let monitor):
            if self.monitor == monitor { self.monitor = nil }
        }
    }

    package var signals: RustDeskSignals {
        RustDeskSignals(peers: connections.map(\.peer), streamedDisplay: monitor.flatMap { displaysOfMonitor[$0] }, monitor: monitor)
    }
}

package struct RustDeskConnection: Equatable, Sendable {
    package var conn: Int
    package var peer: String

    package init(conn: Int, peer: String) {
        self.conn = conn
        self.peer = peer
    }
}
