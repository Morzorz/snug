// 点按吸附：手机上一根手指盖住的面积比鼠标指针大得多，点偏十几个像素很常见。
// 这里只做判定：给一个点、一个控件的框，算出该不该把点击挪到控件中心。真正查询辅助功能在 SnugSystem 的 TapSnapper
import CoreGraphics

public enum TapSnap {
    /// 只吸附这么大的控件：整块窗口、列表容器、桌面图标区都不该把点击吸到中心
    public static let maxControl: CGFloat = 200
    /// 点离控件边缘最多这么远也算点在它上面（往外扩一圈，手指压着边也算）
    public static let margin: CGFloat = 14

    /// tap：手指点的位置；frame：控件在全局坐标里的框；pressable：控件自己能不能「按」（AXPress）
    /// 返回要挪到的点；不该吸附时为 nil
    public static func target(tap: CGPoint, frame: CGRect, pressable: Bool) -> CGPoint? {
        guard pressable, !frame.isEmpty, frame.width <= maxControl, frame.height <= maxControl else { return nil }
        guard frame.insetBy(dx: -margin, dy: -margin).contains(tap) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return center == tap ? nil : center
    }
}
