import Foundation
import RemoteRustDesk
import SnugCore

/// RustDesk：一路信号（日志文件），合成在场、控制端、推流屏。观测走正式的折叠逻辑（RustDeskSessionState），不是直接填
struct RustDeskDriver: RemoteDriver {
    let identity = RustDeskRemote.identity
    let namesControllers = true
    let reportsStreamedDisplay = true
    let injectorPath = "/Applications/RustDesk.app/Contents/MacOS/RustDesk"
    let appBundleID = RustDeskRemote.bundleID

    /// 日志读得到、没有任何连接
    func idle() -> RemoteObservation {
        observation([.closed(conn: 1)])
    }

    /// 日志读不到（没装、没在运行、没权限）
    func unreadable() -> RemoteObservation {
        RustDeskSignals(readable: false).observation()
    }

    func connected(controllers: [String]) -> RemoteObservation {
        observation(controllers.enumerated().flatMap { index, name in
            [RustDeskLogEvent.opened(conn: index + 1, peer: name),
             RustDeskLogEvent.videoStarted(monitor: 0),
             RustDeskLogEvent.display(monitor: 0, id: 1)]
        })
    }

    func streaming(_ display: DisplayID) -> RemoteObservation {
        observation([.opened(conn: 1, peer: "203.0.113.7:63452"),
                     .videoStarted(monitor: 0), .display(monitor: 0, id: display)])
    }

    private func observation(_ events: [RustDeskLogEvent]) -> RemoteObservation {
        var state = RustDeskSessionState()
        for event in events { state.apply(event) }
        return state.signals.observation()
    }
}
