// 点按反馈：手指点下去时在屏上闪一下，看清「点在哪、实际点到哪、吸附圈住的控件有多大」。
// 空心圈是手指位置，实心点是落点，方框是吸附认定的控件（没吸附就没有框）。不接收鼠标，0.7 秒自己消失
import AppKit
import SnugCore
import SnugSystem

@MainActor
final class TapFeedback {
    static let shared = TapFeedback()
    /// 显示多久
    static let duration: TimeInterval = 0.7

    private var window: NSWindow?
    private var hideTask: DispatchWorkItem?

    func show(finger: CGPoint, target: CGPoint, control: CGRect?) {
        guard let display = Self.display(at: finger), let screen = Screens.screen(for: display) else { return }
        let bounds = CGDisplayBounds(display)
        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(screen.frame, display: true)
        (window.contentView as? FeedbackView)?.update(finger: convert(finger, in: bounds), target: convert(target, in: bounds),
                                                       control: control.map { convert($0, in: bounds) })
        window.orderFrontRegardless()
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: task)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = FeedbackView()
        return window
    }

    /// 点在哪块屏上：CG 全局坐标（主屏左上原点、y 向下）
    private static func display(at point: CGPoint) -> DisplayID? {
        (Screens.online() ?? []).first { CGDisplayBounds($0).contains(point) }
    }

    /// CG 全局坐标 → 这块屏的 AppKit 坐标（左下原点、y 向上）
    private func convert(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: point.x - bounds.origin.x, y: bounds.height - (point.y - bounds.origin.y))
    }

    private func convert(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let origin = convert(rect.origin, in: bounds)
        return CGRect(x: origin.x, y: origin.y - rect.height, width: rect.width, height: rect.height)
    }
}

private final class FeedbackView: NSView {
    private var finger: CGPoint?
    private var target: CGPoint?
    private var control: CGRect?

    func update(finger: CGPoint, target: CGPoint, control: CGRect?) {
        self.finger = finger
        self.target = target
        self.control = control
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let finger, let target else { return }
        NSColor.systemYellow.withAlphaComponent(0.85).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: finger.x - 18, y: finger.y - 18, width: 36, height: 36))
        ring.lineWidth = 2
        ring.stroke()

        if let control {
            NSColor.systemBlue.withAlphaComponent(0.75).setStroke()
            let box = NSBezierPath(rect: control)
            box.lineWidth = 2
            box.stroke()
        }

        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: target.x - 4, y: target.y - 4, width: 8, height: 8)).fill()
    }
}
