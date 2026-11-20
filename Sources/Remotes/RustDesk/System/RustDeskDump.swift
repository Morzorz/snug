// --dump-remote rustdesk：打印从 RustDesk 读到的东西和此刻的屏幕。只读，不点 RustDesk、不碰屏幕
import CoreGraphics
import Foundation
import RemoteRustDesk
import SnugCore
import SnugSystem

@MainActor
package enum RustDeskDump {
    package static func run() -> Int32 {
        let watcher = RustDeskLogWatcher()
        watcher.start()
        let signals = watcher.sample()
        print("日志：\(watcher.path)")
        print("  \(watcher.readable ? "读得到" : "读不到")，已读 \(watcher.lineCount) 行")
        print("信号：\(signals.description)")
        print("  在场：\(signals.isPresent ? "是" : "否")")
        if !signals.peers.isEmpty { print("  控制端：\(signals.peers.joined(separator: "、"))") }
        if let display = signals.streamedDisplay { print("  推流屏：#\(display) \(Screens.name(of: display))") }
        print("屏幕：")
        displayLines().forEach { print($0) }
        print("进程：")
        let processes = RustDeskProcesses.list()
        if processes.isEmpty { print("  没有 RustDesk 在运行") }
        for process in processes {
            let role = process.isServer ? "--server" : process.isConnectionManager ? "--cm" : "界面"
            let start = RustDeskProcesses.start(of: process.pid).map { RustDeskCheck.clock($0) } ?? "启动时刻未知"
            print("  pid \(process.pid) \(role)，\(start) 启动")
        }
        return watcher.readable ? 0 : 1
    }

    /// 此刻在线的屏，一行一块
    static func displayLines() -> [String] {
        (Screens.online() ?? []).map { id in
            let mine = CGDisplayVendorNumber(id) == ScreenSpec.vendorID ? "（Snug 的屏）" : ""
            return "  #\(id) \(Screens.name(of: id))\(mine) \(DisplayMode.describe(id))"
        }
    }
}
