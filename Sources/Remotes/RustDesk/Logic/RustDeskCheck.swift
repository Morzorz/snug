// RustDesk 兼容自检（scripts/snug remote-check rustdesk → Snug --check-remote rustdesk）：RustDesk 一更新，
// 把 Snug 依赖它的几处逐项核对，出一份报告。这里只做判定，事实由系统部分（RemoteRustDeskSystem 的 RustDeskCheckRun）收集。
// 日志用正式运行的那套解析与状态（RustDeskLogParser、RustDeskSessionState）回放，查的就是发出去的那套逻辑。
// 只看日志与进程，不点 RustDesk；要先用手机照常连一次再跑
import Foundation
import SnugCore

package enum RustDeskCheck {
    /// 最近一次核对过（自检无问题、手机实测无误）的 RustDesk 版本。核对完新版本后改这里
    package static let verifiedVersion = "1.5.3"
    /// 注入走 enigo，这条路在二进制里留下的模块路径：换掉它，事件上的 eventSourceUserData=100 也就没了
    package static let injectorModule = "libs/enigo/src/macos/macos_impl.rs"
    /// Snug 记到的远程开始，前后这么久内有连入行就算对上
    static let matchWindow: TimeInterval = 15

    package enum Status: Equatable, Sendable {
        case ok, warn, fail, info

        var symbol: String {
            switch self {
            case .ok: "✅"
            case .warn: "⚠️"
            case .fail: "❌"
            case .info: "ℹ️"
            }
        }
    }

    package struct Item: Equatable, Sendable {
        package var status: Status
        package var title: String
        package var detail: String
    }

    /// 此刻的 `--server` 进程
    package struct Server: Equatable, Sendable {
        package var pid: pid_t
        /// 进程启动的时刻；读不到为 nil
        package var start: Date?

        package init(pid: pid_t, start: Date?) {
            self.pid = pid
            self.start = start
        }
    }

    /// 系统部分（RustDeskCheckRun）收集到的事实
    package struct Facts: Sendable {
        package var hours: Int
        package var since: Date
        /// RustDesk 的版本；没装为 nil
        package var version: String?
        /// `--server` 在不在跑：被远程时由它推流、注入操作、写日志
        package var server: Server?
        /// 此刻有没有 `--cm` 在跑（每次连入起一个）；会话结束它不一定马上退，只作参考
        package var connectionManagerRunning: Bool
        /// `--server` 那份日志在时间范围内的行；读不到为 nil
        package var serverLog: [String]?
        package var logPath: String
        /// 包里还有没有注入那条路的模块路径
        package var injectorModulePresent: Bool
        /// Snug 日志的原文（滚动过的旧日志在前）
        package var snugLog: [String]
        /// 此刻在线的 Snug 的屏
        package var onlineSnugDisplays: Set<DisplayID>

        package init(hours: Int, since: Date, version: String?, server: Server?, connectionManagerRunning: Bool,
                     serverLog: [String]?, logPath: String, injectorModulePresent: Bool, snugLog: [String],
                     onlineSnugDisplays: Set<DisplayID>) {
            self.hours = hours
            self.since = since
            self.version = version
            self.server = server
            self.connectionManagerRunning = connectionManagerRunning
            self.serverLog = serverLog
            self.logPath = logPath
            self.injectorModulePresent = injectorModulePresent
            self.snugLog = snugLog
            self.onlineSnugDisplays = onlineSnugDisplays
        }
    }

    /// 用正式运行的解析与状态回放这一段日志
    package struct Replay: Sendable {
        var opens: [Date] = []
        var closes = 0
        var starts: [(date: Date, display: DisplayID?)] = []
        var stops = 0
        /// 回放完的推流状态
        var signals = RustDeskSignals()
    }

    /// 用正式运行的解析与状态回放这一段日志
    package static func replay(_ lines: [String]) -> Replay {
        var state = RustDeskSessionState()
        var replay = Replay()
        for line in lines {
            guard let event = RustDeskLogParser.parse(line) else { continue }
            let date = RustDeskLogParser.stamp(line)
            state.apply(event)
            switch event {
            case .opened:
                if let date { replay.opens.append(date) }
            case .closed:
                replay.closes += 1
            case .videoStarted:
                replay.starts.append((date ?? .distantPast, state.signals.streamedDisplay))
            case .videoStopped:
                replay.stops += 1
            case .display:
                break
            }
        }
        replay.signals = state.signals
        return replay
    }

    package static func evaluate(_ facts: Facts) -> [Item] {
        guard let version = facts.version else {
            return [Item(status: .fail, title: "RustDesk", detail: "没装（按 \(RustDeskRemote.bundleID) 找不到），其余各项无从核对")]
        }
        var items = [Item(status: .ok, title: "RustDesk",
                          detail: "版本 \(version)（\(version == verifiedVersion ? "即上次核对的版本" : "上次核对的是 \(verifiedVersion)")）；"
                              + "核对范围：\(facts.server?.start.map { "\(RustDeskRemote.executableName) \(clock($0)) 启动以来" } ?? "最近 \(facts.hours) 小时")")]
        items.append(process(facts))
        let replay = facts.serverLog.map(Self.replay)
        items += log(facts, replay: replay)
        var snug = SnugLogDigest(lines: facts.snugLog, since: windowStart(facts), remote: RustDeskRemote.identity.logName)
        snug.snugDisplays.formUnion(facts.onlineSnugDisplays)
        if let item = detection(snug, replay: replay) { items.append(item) }
        if let item = display(facts, replay: replay) { items.append(item) }
        items.append(injector(facts))
        return items
    }

    package static func report(_ items: [Item], hours: Int, at date: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MM-dd HH:mm"
        let fails = items.filter { $0.status == .fail }.count
        let warns = items.filter { $0.status == .warn }.count
        let verdict = fails > 0 ? "发现 \(fails) 项问题" : warns > 0 ? "未发现问题，\(warns) 项需留意" : "未发现兼容问题"
        return (["RustDesk 兼容自检 · \(stamp.string(from: date)) · 回看 \(hours) 小时", "结论：\(verdict)", ""]
            + items.map { "\($0.status.symbol) \($0.title)：\($0.detail)" }).joined(separator: "\n")
    }


    /// Snug 日志从哪儿起算：RustDesk 重启过就从它启动算，比回看窗口更准（日志文件是一份接一份）
    static func windowStart(_ facts: Facts) -> Date {
        facts.server?.start.flatMap { $0 > facts.since ? $0 : nil } ?? facts.since
    }

    package static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: 逐项

    private static func process(_ facts: Facts) -> Item {
        let name = RustDeskRemote.executableName
        guard let server = facts.server else {
            return Item(status: .warn, title: "后台进程",
                        detail: "没在运行 \(name) --server：远程时由它推流、注入操作、写日志。打开 RustDesk 后再用手机连一次")
        }
        let cm = facts.connectionManagerRunning ? "；此刻有 --cm（有会话或它的窗口还开着）" : ""
        return Item(status: .ok, title: "后台进程", detail: "\(name) --server 在运行（pid \(server.pid)）\(cm)")
    }

    private static func log(_ facts: Facts, replay: Replay?) -> [Item] {
        guard let serverLog = facts.serverLog, let replay else {
            return [Item(status: .warn, title: "日志", detail: "读不出 \(facts.logPath)：连接判定与推流屏都靠它，无从核对")]
        }
        let file = Item(status: .ok, title: "日志",
                        detail: "\(facts.logPath)，\(serverLog.count) 行；认出连入 \(replay.opens.count) 次、断开 \(replay.closes) 次、"
                            + "推流开始 \(replay.starts.count) 次、停止 \(replay.stops) 次")
        guard !replay.opens.isEmpty else {
            return [file, Item(status: .warn, title: "连接行",
                               detail: "这段时间没有可认的连入行：用手机连一次再跑。写法或日志级别变了的话，连接判定只剩「推流那一路」（\(facts.logPath)）")]
        }
        return [file]
    }

    /// Snug 连入时信号快照里认出了什么：控制端、推流屏。远程过却一次连入都认不出，多半是 Snug 自己的日志写法改了
    private static func detection(_ snug: SnugLogDigest, replay: Replay?) -> Item? {
        let sessions = snug.sessionStarts.count
        let all = snug.detections
        guard !all.isEmpty else {
            guard sessions > 0 else { return nil }
            return Item(status: .warn, title: "连接检测",
                        detail: "\(sessions) 次远程，Snug 日志里却没有一次「检测到 \(RustDeskRemote.identity.logName) 连入」：日志写法可能改了")
        }
        let logged = all.compactMap { RustDeskSignals.logged($0.evidence) }
        let unreadable = all.count - logged.count
        let named = logged.compactMap { $0.peer }
        let matched = replay.map { r in all.filter { d in r.opens.contains { abs($0.timeIntervalSince(d.date)) <= matchWindow } }.count } ?? 0
        let extra = (named.isEmpty ? "控制端一次都没认出（RustDesk 只在连入行里写地址:端口）" : "认出控制端 \(Set(named).sorted().joined(separator: "、"))")
            + (unreadable > 0 ? "；\(unreadable) 次连入的信号快照读不出" : "")
        if matched == 0 {
            return Item(status: .warn, title: "连接检测", detail: "\(all.count) 次连入与日志里的连入行都对不上（\(extra)）")
        }
        let status: Status = matched == all.count && unreadable == 0 && named.isEmpty ? .warn : .ok
        return Item(status: status, title: "连接检测", detail: "日志里的连入行对得上 \(matched)/\(all.count) 次（\(extra)）")
    }

    private static func display(_ facts: Facts, replay: Replay?) -> Item? {
        guard let replay else { return nil }
        var seen: [DisplayID] = []
        for start in replay.starts.compactMap(\.display) where !seen.contains(start) { seen.append(start) }
        guard !seen.isEmpty else {
            return replay.starts.isEmpty ? nil
                : Item(status: .fail, title: "推流屏", detail: "推流过 \(replay.starts.count) 次，却一次都没认出推的是哪块屏（`#displays=` 行没了）：切屏与主屏判断都会出错")
        }
        let list = seen.map { "#\($0)" }.joined(separator: "、")
        let mine = seen.filter(facts.onlineSnugDisplays.contains)
        guard !mine.isEmpty else {
            return Item(status: .info, title: "推流屏", detail: "推过 \(list)；这段时间没推过 Snug 的屏，切屏能否认出待下次核对")
        }
        return Item(status: .ok, title: "推流屏", detail: "推过 \(list)，其中 Snug 的屏 \(mine.map { "#\($0)" }.joined(separator: "、"))：切到 Snug 的屏认得出")
    }

    /// 手势只接管 RustDesk 注入的事件：注入走 enigo 这条路还在，事件上的 userData 才还是 100
    private static func injector(_ facts: Facts) -> Item {
        guard facts.injectorModulePresent else {
            return Item(status: .warn, title: "注入来源",
                        detail: "包里的程序找不到 \(injectorModule)：注入可能换了实现，事件上的 eventSourceUserData 未必还是 "
                            + "\(RustDeskRemote.injectedUserData)，手势会认不出来（按程序名 \(RustDeskRemote.executableName) 认的那一半还成立）")
        }
        return Item(status: .ok, title: "注入来源",
                    detail: "注入仍走 enigo：手势按 \(RustDeskRemote.executableName) + eventSourceUserData=\(RustDeskRemote.injectedUserData) 认")
    }
}
