// 手势翻译和 CGEvent 之间的读写：接管哪几种事件、事件类型对应 TouchInput 的哪一种、拼要补发的事件、打上记号发出去；
// InjectedEvents 认哪些事件是远控注入的。监听线程、状态机和按 TouchCommand 分派在 TouchTap。
// 补发的事件打上记号：拷贝出来的事件保留远控的进程号，不打记号会被自己再接管一次，来回打转
import CoreGraphics
import Darwin
import Foundation
import SnugCore

enum TouchEvents {
    /// eventSourceUserData 里的记号（'SNUG'）
    private static let marker: Int64 = 0x534E_5547

    /// 接管的事件：鼠标左键的按下、拖动、抬起，外加不按键的移动。
    /// 有的远控（RustDesk 触摸模式）把手指滑动发成「不按键的移动」，只在点按时发按下、抬起，移动要当轨迹用（见 TouchTap）
    static let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

    static func kind(of type: CGEventType) -> TouchInput.Kind? {
        switch type {
        case .leftMouseDown: .press
        case .leftMouseDragged: .drag
        case .leftMouseUp: .release
        default: nil
        }
    }

    /// Snug 自己补发的事件
    static func isReplay(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// 打上记号再发。记号写在事件源上：eventSourceUserData 是源的属性，从远控事件拷贝出来的那份改不动
    /// （RustDesk 的事件源把值写成 100，改字段读回来还是 100），所以补发要用自己的源重建事件，见 replay(_:)
    static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.post(tap: .cghidEventTap)
    }

    /// 按原事件的类型和位置重建一个左键事件：只带走点击计数与修饰键，其余从零开始。
    /// 源是我们自己的（记号写在源上），记号才带得动；远控那份拷贝带着它自己的源，无论怎么改字段都还是它的值
    static func replay(_ original: CGEvent) -> CGEvent? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        source.userData = marker
        guard let event = CGEvent(mouseEventSource: source, mouseType: original.type,
                                  mouseCursorPosition: original.location, mouseButton: .left) else { return nil }
        event.setIntegerValueField(.mouseEventClickState, value: original.getIntegerValueField(.mouseEventClickState))
        event.flags = original.flags
        return event
    }

    /// 右键按下、抬起
    static func rightClick(at point: CGPoint) -> [CGEvent] {
        [CGEventType.rightMouseDown, .rightMouseUp].compactMap { type in
            let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)
            click?.setIntegerValueField(.mouseEventClickState, value: 1)
            return click
        }
    }

    /// 带相位的像素滚动：App 看到的和触控板两指滑动一样
    static func scroll(_ s: ScrollStep) -> CGEvent? {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: s.pixelsY, wheel2: s.pixelsX, wheel3: 0) else { return nil }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: s.phase.rawValue)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: s.momentum.rawValue)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.deltaY)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.deltaX)
        e.location = s.location
        return e
    }
}

/// 认远控注入的事件：按来源进程号查可执行文件路径、连同事件自带的 eventSourceUserData，交给各家的 InjectedEventSource 判断，
/// 路径按进程号缓存（每拍事件多，只查一次）。本机的触控板、鼠标不是它们发的，一律不认
struct InjectedEvents {
    let injectors: [InjectedEventSource]
    private var paths: [pid_t: String] = [:]

    init(injectors: [InjectedEventSource]) {
        self.injectors = injectors
    }

    mutating func contains(_ event: CGEvent) -> Bool {
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid > 0 else { return false }
        let path = paths[pid] ?? Self.executablePath(of: pid)
        paths[pid] = path
        let userData = event.getIntegerValueField(.eventSourceUserData)
        return injectors.contains { $0.matches(executablePath: path, userData: userData) }
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        return length > 0 ? String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }
}

