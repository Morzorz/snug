// 手势翻译的系统部分：一个事件监听，只接管远控注入、在某块范围里按下的鼠标左键（每块要翻译手势的屏一块），
// 交给 TouchTranslator 判断，再照它说的补发点击、右键或滚动（事件怎么读、怎么拼见 TouchEvents）。本机的触控板、鼠标一律不碰。
// 跑在独立线程上：主线程会被建屏、搬窗口卡住，监听回调一慢，系统会让全机的鼠标跟着卡
import CoreGraphics
import Foundation
import os
import SnugCore

/// 主线程用的开关。每次开启是一个独立的监听会话：关掉马上再开，新旧两个线程互不共用状态
@MainActor
public final class TouchTap {
    /// 手势翻译管的范围（CGEvent 坐标），每块要翻译手势的屏一块。主线程写，监听线程读
    private let regions = OSAllocatedUnfairLock<[TouchRegion]>(initialState: [])
    private var session: TapSession?
    /// 接管哪些进程注入的事件：各家已登记的远控
    private let injectors: [InjectedEventSource]
    /// 手机上点了屏上那个窗口的关闭按钮（核对过、点击已经吞掉了），交回窗口编号：在主线程上调
    public var onCloseWindow: ((UInt32) -> Void)?
    /// 点按反馈：手指位置、实际落点、吸附到的控件框（没吸附为 nil）。在监听线程上回调，主线程画
    public var onTapFeedback: (@Sendable (CGPoint, CGPoint, CGRect?) -> Void)?

    public init(injectors: [InjectedEventSource]) {
        self.injectors = injectors
    }

    /// 只在这几块范围里翻译手势，一块都没有就关掉监听。范围变了（换档、屏幕重排）照样调，监听不用重开。
    /// 要翻译却建不起事件监听（多半是没有辅助功能权限）时交回 false，下次调用再试
    public func setRegions(_ regions: [TouchRegion]) -> Bool {
        self.regions.withLock { $0 = regions }
        guard !regions.isEmpty else {
            stop()
            return true
        }
        return start()
    }

    /// 起监听线程，等它报告监听建没建成
    private func start() -> Bool {
        guard session == nil else { return true }
        let feedback = onTapFeedback
        let next = TapSession(regions: regions, injectors: injectors, feedback: feedback) { [weak self] window in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onCloseWindow?(window) } }
        }
        guard next.start() else {
            Log.error("手势翻译开不起来：建事件监听失败（多半是没有辅助功能权限）")
            return false
        }
        session = next
        Log.info("手势翻译已开启（只接管 \(injectors.map(\.description).joined(separator: "、")) 发来、在 Snug 屏里的操作）")
        return true
    }

    private func stop() {
        guard let session else { return }
        session.stop()
        self.session = nil
        Log.info("手势翻译已关闭")
    }
}

/// 一次监听：自己的线程、自己的 run loop、自己的状态机。除了 start / stop，其余都只在这个线程上跑
private final class TapSession: @unchecked Sendable {
    private let regions: OSAllocatedUnfairLock<[TouchRegion]>
    private let closeWindow: @Sendable (UInt32) -> Void
    /// 点按反馈：手指位置、落点、吸附到的控件框
    private let feedback: (@Sendable (CGPoint, CGPoint, CGRect?) -> Void)?
    /// 监听线程的 run loop：start 等它建好才返回，之后只读
    private var runLoop: CFRunLoop?

    // 以下只在监听线程上访问
    private var tap: CFMachPort?
    private var translator = TouchTranslator()
    private var heldPress: CGEvent?
    private var coastTimer: CFRunLoopTimer?
    private var injected: InjectedEvents
    /// 有的远控把手指滑动发成「不按键的移动」、点按发成单独一个抬起（RustDesk 触摸模式实测）。
    /// 这里把移动当手指轨迹，合成翻译器认识的按下/拖动/抬起；原事件吞掉，光标不再跟着手指跑。
    /// 见过真正的左键拖动（UU 那类）就别对接，免得同一根手指算两遍
    private var finger: CGPoint?
    private var fingerStarted = false
    private var fingerStartedAt: TimeInterval = 0
    /// 这次手势已经滚过：按住不动才取消，滚动过的照常收尾
    private var fingerScrolled = false
    private var fingerLastMove: TimeInterval = 0
    private var lastDragAt: TimeInterval = -10
    private var fingerTimer: CFRunLoopTimer?
    /// 远控自己处理了长按右键，这一小段时间里来的左键抬起不要补点击（会把刚弹出的菜单点掉）
    private var suppressUntil: TimeInterval = 0

    /// 手指停这么久算这一次手势结束（远控只在移动时发事件，停手就没有后续了）。
    /// 要比长按阈值长：按住不动是在等右键菜单，不能提前当成点击
    private static let fingerIdle: TimeInterval = 0.6
    /// 这么久内出现过真正的左键拖动，就不把移动当手指轨迹
    private static let dragQuiet: TimeInterval = 1.5
    /// 这一下按在哪块范围里：之后的拖动、抬起跟着这一下走，手指滑出范围也一样
    private var pressed: TouchRegion?

    init(regions: OSAllocatedUnfairLock<[TouchRegion]>, injectors: [InjectedEventSource],
         feedback: (@Sendable (CGPoint, CGPoint, CGRect?) -> Void)?, closeWindow: @escaping @Sendable (UInt32) -> Void) {
        self.regions = regions
        injected = InjectedEvents(injectors: injectors)
        self.feedback = feedback
        self.closeWindow = closeWindow
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let ok = installTap()
            if ok { runLoop = CFRunLoopGetCurrent() }
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "com.zephyr4123.snug.touch"
        thread.qualityOfService = .userInteractive
        thread.start()
        // 建监听是同步的、很快，不设超时：设了超时反而会在超时后留下一个关不掉的监听。
        // signal / wait 也保证监听线程对 runLoop 的写入在这里可见
        ready.wait()
        return runLoop != nil
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            tap = nil
            finishFinger(at: nil, now: ProcessInfo.processInfo.systemUptime)
            stopCoasting()
            heldPress = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func installTap() -> Bool {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: TouchEvents.mask, callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<TapSession>.fromOpaque(info).takeUnretainedValue().handle(type, event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.warn("手势翻译的事件监听被系统停用（\(type == .tapDisabledByTimeout ? "回调超时" : "用户输入")），已重新开启")
            return pass
        }
        let now = ProcessInfo.processInfo.systemUptime
        if TouchEvents.isReplay(event) { return pass }
        guard injected.contains(event) else { return pass }

        if type == .mouseMoved {
            return followFinger(event, now: now)
        }
        if type == .rightMouseDown || type == .rightMouseUp {
            // 远控自己把长按变成了右键：这一次手势让给它，Snug 不再补点击、也不自己再点一次右键。
            // 菜单就开在手指下面，它随后那个左键事件（按在同一个点上）会点中菜单项，要一并让开
            discardFinger(now: now)
            return pass
        }
        guard let kind = TouchEvents.kind(of: type) else { return pass }
        if kind == .drag { lastDragAt = now }
        // 合成的手势进行中：远控真实的按下（坐标多半是滞后的）不要打断轨迹
        if fingerStarted {
            if kind == .release { finishFinger(at: event.location, now: now) }
            return nil
        }

        // 刚让位给远控的右键：跟着来的左键抬起不要点（会把菜单点掉）
        if kind == .release, now < suppressUntil { return nil }

        // 有的远控点按只发一个抬起、不发按下（RustDesk 触摸模式实测）：按它给的位置补一次干净的点击
        if kind == .release, pressed == nil, !fingerStarted {
            let point = event.location
            guard regions.withLock({ $0 }).contains(where: { $0.frame.contains(point) }) else { return pass }
            tap(at: point, now: now)
            return nil
        }

        let input = TouchInput(kind, at: event.location, time: now)
        if kind == .press { pressed = regions.withLock { $0 }.first { $0.frame.contains(event.location) } }
        let response = translate(input, current: event)
        return response.passOriginal ? pass : nil
    }

    /// 在这一点上合成一次点击：先按下、再抬起，走翻译器的点击那条路（连击计数、关闭按钮都不落下）
    private func tap(at raw: CGPoint, now: TimeInterval) {
        let snap = TapSnapper.snap(raw)
        feedback?(raw, snap.point, snap.control)
        let point = snap.point
        pressed = regions.withLock { $0 }.first { $0.frame.contains(point) }
        _ = translate(TouchInput(.press, at: point, time: now), current: synthetic(.leftMouseDown, at: point))
        _ = translate(TouchInput(.release, at: point, time: now + 0.05), current: synthetic(.leftMouseUp, at: point))
        pressed = nil
    }

    /// 不按键的移动：当作手指轨迹。落在某块范围里就自己起一次手势（按下 → 拖动…），
    /// 停手 fingerIdle 之后按「抬起」收尾；出了范围也收尾。原事件吞掉，光标留在原处
    private func followFinger(_ event: CGEvent, now: TimeInterval) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard now >= suppressUntil else { return nil }
        guard now - lastDragAt >= Self.dragQuiet else { return pass }
        let point = event.location
        guard let region = regions.withLock({ $0 }).first(where: { $0.frame.contains(point) }) else {
            finishFinger(at: nil, now: now)
            return pass
        }
        finger = point
        fingerLastMove = now
        pressed = region
        if fingerStarted {
            // 喂给翻译器的必须是真正的拖动事件：补发时按它的类型重建，移动事件补出去不会是拖动
            _ = translate(TouchInput(.drag, at: point, time: now), current: synthetic(.leftMouseDragged, at: point))
        } else {
            fingerStarted = true
            fingerStartedAt = now
            fingerScrolled = false
            // 按下时吸附一次：手指盖住的面积大，点在按钮边上也算点到它
            let snap = TapSnapper.snap(point)
            feedback?(point, snap.point, snap.control)
            _ = translate(TouchInput(.press, at: snap.point, time: now), current: synthetic(.leftMouseDown, at: snap.point))
        }
        armFingerTimer()
        return nil
    }

    /// 收尾：按手指最后的位置给翻译器一个抬起，点击、右键、滚动都在这一步定下来
    private func finishFinger(at point: CGPoint?, now: TimeInterval) {
        guard fingerStarted else { return }
        fingerStarted = false
        stopFingerTimer()
        // 按住不动：右键由远控自己发（实测 RustDesk 触摸模式会发 rdown/rup）。Snug 不再补，
        // 否则菜单刚出来就被自己这一下点中某一项。滚动过的手势不算长按，照常收尾
        if !fingerScrolled, now - fingerStartedAt >= TouchTranslator.holdDuration {
            discardFinger(now: now)
            return
        }
        let end = point ?? finger ?? .zero
        _ = translate(TouchInput(.release, at: end, time: now), current: synthetic(.leftMouseUp, at: end))
        finger = nil
        pressed = nil
    }

    /// 这一次合成手势作废：远控自己处理了（比如长按右键），Snug 不补任何事件，翻译器重来
    private func discardFinger(now: TimeInterval) {
        fingerStarted = false
        stopFingerTimer()
        translator = TouchTranslator()
        heldPress = nil
        finger = nil
        pressed = nil
        fingerScrolled = false
        suppressUntil = now + 1.2
    }

    /// 喂翻译器并按它说的做：吞事件、补发按下、右键、滚动
    @discardableResult
    private func translate(_ input: TouchInput, current: CGEvent?) -> TouchResponse {
        let region = pressed
        let response = translator.handle(input, in: region)
        if input.kind == .press, !response.passOriginal { heldPress = current?.copy() }
        if response.commands.contains(where: { if case .scroll = $0 { true } else { false } }) { fingerScrolled = true }
        if let current { response.commands.forEach { perform($0, current: current, region: region) } }
        if input.kind == .release { heldPress = nil }
        if translator.isCoasting { startCoasting() }
        return response
    }

    /// 按类型在这一点上造一个左键事件（源留空：记号由 TouchEvents.replay 写在它自己的源上）
    private func synthetic(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    }

    private func armFingerTimer() {
        stopFingerTimer()
        // 滚动过的手势不用等长按那么久：停手就是停手，惯性早点接上
        let idle = fingerScrolled ? 0.12 : Self.fingerIdle
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + idle, 0, 0, 0) { [self] _ in
            finishFinger(at: nil, now: ProcessInfo.processInfo.systemUptime)
        }
        fingerTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    private func stopFingerTimer() {
        guard let timer = fingerTimer else { return }
        CFRunLoopTimerInvalidate(timer)
        fingerTimer = nil
    }

    private func perform(_ command: TouchCommand, current: CGEvent, region: TouchRegion?) {
        switch command {
        case .replayPress:
            TouchEvents.post(heldPress.flatMap(TouchEvents.replay))
            heldPress = nil
        case .replayCurrent:
            TouchEvents.post(TouchEvents.replay(current))
        case .rightClick(let point):
            TouchEvents.rightClick(at: point).forEach(TouchEvents.post)
        case .scroll(let step):
            TouchEvents.post(TouchEvents.scroll(step))
        case .closeWindow(let point):
            // 按钮位置是铺好时读的：点下去这一刻再问一次窗口服务器（不经过 App，很快），对不上就照常点
            if let button = region?.closeButton, button.isFrontmost(at: point, onScreen: Self.onScreen()) {
                closeWindow(button.window)
            } else {
                Log.info("点在屏上那个窗口原来的关闭按钮处，但那里已经不是它的关闭按钮（挪走、被盖住或全屏了），照常点击")
                perform(.replayPress, current: current, region: region)
                perform(.replayCurrent, current: current, region: region)
            }
        }
    }

    /// 窗口服务器里此刻在屏上的窗口，从前到后
    private static func onScreen() -> [(id: UInt32, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return (list ?? []).compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (id, frame)
        }
    }

    /// 惯性：在监听线程的 run loop 上按 60fps 走，走完自己停
    private func startCoasting() {
        guard coastTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1 / Momentum.frameRate, 0, 0) { [self] _ in
            if let step = translator.momentumFrame() { TouchEvents.post(TouchEvents.scroll(step)) }
            if !translator.isCoasting { stopCoasting() }
        }
        coastTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    private func stopCoasting() {
        guard let timer = coastTimer else { return }
        CFRunLoopTimerInvalidate(timer)
        coastTimer = nil
    }
}
