import CoreGraphics
import Testing
@testable import SnugCore

@Suite("点按吸附 TapSnap")
struct TapSnapTests {
    private let button = CGRect(x: 100, y: 100, width: 80, height: 32)

    @Test("点在按钮上、或压在边上：挪到按钮中心")
    func snapsToControl() {
        #expect(TapSnap.target(tap: CGPoint(x: 110, y: 110), frame: button, pressable: true) == CGPoint(x: 140, y: 116))
        #expect(TapSnap.target(tap: CGPoint(x: 95, y: 130), frame: button, pressable: true) == CGPoint(x: 140, y: 116))
        #expect(TapSnap.target(tap: CGPoint(x: 140, y: 116), frame: button, pressable: true) == nil)
    }

    @Test("离得太远、不能按、或者框太大（窗口、容器）：都不吸附")
    func leavesAlone() {
        #expect(TapSnap.target(tap: CGPoint(x: 60, y: 60), frame: button, pressable: true) == nil)
        #expect(TapSnap.target(tap: CGPoint(x: 110, y: 110), frame: button, pressable: false) == nil)
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(TapSnap.target(tap: CGPoint(x: 380, y: 280), frame: window, pressable: true) == nil)
        #expect(TapSnap.target(tap: .zero, frame: .zero, pressable: true) == nil)
    }
}
