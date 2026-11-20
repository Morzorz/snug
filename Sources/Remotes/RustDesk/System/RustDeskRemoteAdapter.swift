// RustDesk 的适配器：每拍读一次 RustDesk 写的日志（连接、断开、推流与推的是哪块屏），合成一份观测。
// 不读界面、不查进程表：日志里三样都有，少一路信号少一处失效点
import Foundation
import RemoteRustDesk
import SnugCore

@MainActor
package final class RustDeskRemoteAdapter: RemoteAdapter {
    package static let identity = RustDeskRemote.identity
    private let log = RustDeskLogWatcher()

    package init() {}

    package func start() { log.start() }
    package func stop() {}

    package func sample(wallClock: Date) -> RemoteObservation {
        log.sample().observation()
    }
}
