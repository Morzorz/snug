// RustDesk 的身份。各处认 RustDesk（手势只接管它注入的操作、App 资源库里排除它）都认这里。
// 事实来源：docs/remote-adapter/research/rustdesk.md（1.5.3 本机实测 + tag 1.5.3 源码）
import Foundation
import SnugCore

package enum RustDeskRemote {
    /// 1.5.3 的 Info.plist：全小写
    package static let bundleID = "com.carriez.rustdesk"
    /// 界面、`--server`（常驻、被远程时推流与注入操作）、`--cm`（每次连入起一个）是同一个可执行文件，只是启动参数不同
    package static let executableName = "RustDesk"
    /// 注入鼠标键盘时写死在事件上（enigo 的 ENIGO_INPUT_EXTRA_VALUE）：界面进程与注入进程同一个路径，靠它区分
    package static let injectedUserData: Int64 = 100

    package static let identity = RemoteIdentity(logName: "RustDesk", displayName: "RustDesk", bundleIDs: [bundleID],
                                                injector: InjectedEventSource(executableName: executableName,
                                                                              userData: injectedUserData))
}
