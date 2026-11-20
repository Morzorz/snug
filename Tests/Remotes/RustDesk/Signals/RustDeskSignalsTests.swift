import Foundation
import SnugCore
import Testing
@testable import RemoteRustDesk

@Suite("RustDesk 信号与身份")
struct RustDeskSignalsTests {
    @Test("连入即在场：控制端是日志里的地址:端口，快照按 peer= display= video= 写")
    func connected() {
        var state = RustDeskSessionState()
        state.apply(.opened(conn: 642, peer: "203.0.113.7:63452"))
        let signals = state.signals
        #expect(signals.isPresent)
        #expect(signals.peers == ["203.0.113.7:63452"])
        #expect(signals.streamedDisplay == nil)
        #expect(signals.description == "peer=203.0.113.7:63452 display=未知 video=否")
        #expect(signals.observation().present)
        #expect(signals.observation().controllers == ["203.0.113.7:63452"])
    }

    @Test("断开即缺席；认得连入行时，最后一个连接断开就把推流一起清掉（停流那行漏了也不能一直算在场）")
    func disconnected() {
        var state = RustDeskSessionState()
        state.apply(.opened(conn: 1, peer: "198.51.100.9:52144"))
        state.apply(.videoStarted(monitor: 0))
        state.apply(.display(monitor: 0, id: 3))
        #expect(state.signals.isPresent)
        state.apply(.closed(conn: 1))
        #expect(!state.signals.isPresent)
        #expect(state.signals.streamedDisplay == nil)
        #expect(state.signals.monitor == nil)
    }

    @Test("日志级别调高、认不出连入行时，推流那一路仍算在场（INFO 兜底），控制端报未识别")
    func streamingWithoutOpenLine() {
        var state = RustDeskSessionState()
        state.apply(.videoStarted(monitor: 0))
        state.apply(.display(monitor: 0, id: 1))
        #expect(state.signals.isPresent)
        #expect(state.signals.peers.isEmpty)
        #expect(state.signals.description == "peer=未识别 display=1 video=monitor0")
    }

    @Test("换屏跟随：新的一路起、旧的一路停，推流屏跟着变")
    func switchDisplay() {
        var state = RustDeskSessionState()
        state.apply(.opened(conn: 1, peer: "A:1"))
        state.apply(.videoStarted(monitor: 0))
        state.apply(.display(monitor: 0, id: 1))
        state.apply(.videoStarted(monitor: 1))
        state.apply(.display(monitor: 1, id: 3))
        state.apply(.videoStopped(monitor: 0))
        #expect(state.signals.streamedDisplay == 3)
        #expect(state.signals.monitor == 1)
        // 停的不是当前那一路：不动
        state.apply(.videoStopped(monitor: 0))
        #expect(state.signals.streamedDisplay == 3)
    }

    @Test("屏描述先到、推流后到：先记下 monitor 与屏的对应，推流一开始就认得出屏")
    func displayBeforeStream() {
        var state = RustDeskSessionState()
        state.apply(.display(monitor: 0, id: 79))
        state.apply(.videoStarted(monitor: 0))
        #expect(state.signals.streamedDisplay == 79)
    }

    @Test("读不到日志：不在场，快照写「日志=读不到」，自检那头也读不回来")
    func unreadable() {
        let signals = RustDeskSignals(readable: false)
        #expect(!signals.isPresent)
        #expect(signals.description == "日志=读不到")
        #expect(RustDeskSignals.logged(signals.description) == nil)
        #expect(!signals.observation().present)
        #expect(signals.observation().evidence == "日志=读不到")
    }

    @Test("信号快照往返：description 写进日志，自检按同一写法读回来")
    func logged() throws {
        var state = RustDeskSessionState()
        state.apply(.opened(conn: 1, peer: "203.0.113.7:63452"))
        state.apply(.videoStarted(monitor: 1))
        state.apply(.display(monitor: 1, id: 3))
        let logged = try #require(RustDeskSignals.logged(state.signals.description))
        #expect(logged.peer == "203.0.113.7:63452")
        #expect(logged.display == 3)
        #expect(logged.video == "monitor1")
        // 认不出控制端、不知道屏的时候，读回来是 nil 而不是编一个
        var bare = RustDeskSessionState()
        bare.apply(.videoStarted(monitor: 0))
        let partial = try #require(RustDeskSignals.logged(bare.signals.description))
        #expect(partial.peer == nil)
        #expect(partial.display == nil)
        #expect(partial.video == "monitor0")
    }

    @Test("身份：1.5.3 的 bundle 全小写；注入事件按程序名 + eventSourceUserData=100 认")
    func identity() {
        #expect(RustDeskRemote.bundleID == "com.carriez.rustdesk")
        let identity = RustDeskRemote.identity
        #expect(identity.logName == "RustDesk")
        #expect(identity.displayName == "RustDesk")
        #expect(identity.bundleIDs == ["com.carriez.rustdesk"])
        #expect(identity.injector.executableName == "RustDesk")
        #expect(identity.injector.userData == 100)
        #expect(identity.injector.description == "RustDesk（eventSourceUserData 100）")
        #expect(identity.injector.matches(executablePath: "/Applications/RustDesk.app/Contents/MacOS/RustDesk", userData: 100))
        #expect(!identity.injector.matches(executablePath: "/Applications/RustDesk.app/Contents/MacOS/RustDesk", userData: 0))
    }
}
