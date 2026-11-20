// 点按吸附的系统部分：问辅助功能「这一点上是什么元素」，它或往上几层能按、而且是控件大小，
// 就把点击挪到控件中心（判定在 SnugCore 的 TapSnap）。
//
// 两件必须守住的事：
// 1. 查询绝不能拖住手势。辅助功能调用会等对方进程回应，返回的元素还走它自己的超时（默认约 6 秒），
//    在监听线程上同步查会把整条输入链卡死（2026-11-20 实测卡死过一次）。所以查询跑在独立串行队列上，
//    只等 20ms；没赶上就原样点击，卡住的那次也不影响下一次（同一时间只放一个查询进去）。
// 2. 不能查 Snug 自己的窗口：那会在后台线程上生成自己的辅助功能树，SwiftUI 的视图闭包是主线程隔离的，
//    被后台线程调用会直接 SIGTRAP（同一天实测崩了四次）。
import ApplicationServices
import CoreGraphics
import SnugCore

enum TapSnapper {
    /// 往上找几层：点到的常是按钮里的文字、图标，能按的是它的父级
    static let depth = 3
    /// 每个元素问辅助功能最多等这么久
    static let timeout: Float = 0.08
    /// 整次吸附最多花这么久：查得慢就放弃、原样点（延迟比精度更伤手感）
    static let budget: TimeInterval = 0.03
    /// 手势线程最多等查询这么久
    static let wait: TimeInterval = 0.02
    /// 子节点超过这么多就不扫：大容器的子节点查询最费时间
    static let maxChildren = 80

    /// 吸附结果：落点，以及认定出来的控件框（没吸附时为 nil，画反馈用）
    struct Result {
        var point: CGPoint
        var control: CGRect?
    }

    private static let queue = DispatchQueue(label: "com.zephyr4123.snug.tapsnap", qos: .userInitiated)
    private static let inFlight = Locked(false)
    private static let box = Locked(Result(point: .zero, control: nil))

    /// 把这一点吸附到附近的控件中心；没有可吸附的控件、或者查询没赶上，就原样返回
    static func snap(_ point: CGPoint) -> Result {
        guard AX.isTrusted else { return Result(point: point, control: nil) }
        // 上一次查询还没回来（可能正卡在某个进程上）：这次不吸，原样点，别把队列越堆越长
        let started = inFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard started else { return Result(point: point, control: nil) }

        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            let result = query(point)
            box.withLock { $0 = result }
            inFlight.withLock { $0 = false }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + wait) == .success else {
            return Result(point: point, control: nil)
        }
        return box.withLock { $0 }
    }

    private static func query(_ point: CGPoint) -> Result {
        let start = Date()
        let element = hitTest(point)
        guard var current = element else { return Result(point: point, control: nil) }
        // 点是落在 Snug 自己的窗口上：不查（见文件头第 2 条）
        if pid(of: current) == getpid() { return Result(point: point, control: nil) }
        var scanned = false
        for _ in 0..<depth {
            if Date().timeIntervalSince(start) > budget { break }
            touch(current)
            if let frame = frame(of: current),
               let target = TapSnap.target(tap: point, frame: frame, pressable: pressable(current)) {
                Log.info("点按吸附：(\(Int(point.x)),\(Int(point.y))) → 控件中心 (\(Int(target.x)),\(Int(target.y)))")
                return Result(point: target, control: frame)
            }
            if !scanned, Date().timeIntervalSince(start) < budget, let nearest = nearestControl(in: current, to: point) {
                Log.info("点按吸附：(\(Int(point.x)),\(Int(point.y))) → 附近控件的中心 (\(Int(nearest.point.x)),\(Int(nearest.point.y)))")
                return nearest
            }
            scanned = true
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return Result(point: point, control: nil)
    }

    /// 在容器的子节点里找最近的可按控件：点和它的框（外扩一圈）相交就算，取中心最近的那个
    private static func nearestControl(in container: AXUIElement, to point: CGPoint) -> Result? {
        var best: (distance: CGFloat, result: Result)?
        for child in children(of: container).prefix(maxChildren) {
            touch(child)
            guard let frame = frame(of: child), let target = TapSnap.target(tap: point, frame: frame, pressable: pressable(child)) else { continue }
            let distance = hypot(target.x - point.x, target.y - point.y)
            if best == nil || distance < best!.distance { best = (distance, Result(point: target, control: frame)) }
        }
        return best?.result
    }

    private static func hitTest(_ point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        touch(systemWide)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    /// 每个元素单独设超时：从别的进程取回的元素带的是它自己的默认超时（约 6 秒）
    private static func touch(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func pressable(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return [] }
        return list
    }

    private static func parentElement(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXValue.self)
    }
}
