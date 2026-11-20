// RustDesk 的进程：界面、`--server`、`--cm` 是同一个可执行文件，靠启动参数区分（1.5.3 实测 + tag 1.5.3 源码：
// `--server` 由 service 拉起、长期驻留，每次连入再由它起一个 `--cm`）。
// 只给诊断与兼容自检用：连接判定看日志，不看进程（`--cm` 会话结束后不一定马上退，拿它判在场会误判）
import Foundation
import RemoteRustDesk

struct RustDeskProcess: Equatable, Sendable {
    let pid: pid_t
    let arguments: [String]

    var isServer: Bool { arguments.contains("--server") }
    var isConnectionManager: Bool { arguments.contains("--cm") }
    var describeArguments: String { arguments.dropFirst().joined(separator: " ") }
}

enum RustDeskProcesses {
    /// 此刻跑着的 RustDesk（同一个可执行文件的任何身份）
    static func list() -> [RustDeskProcess] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        return pids.prefix(min(count, pids.count)).compactMap { pid in
            guard pid > 0, executablePath(of: pid).map({ ($0 as NSString).lastPathComponent }) == RustDeskRemote.executableName,
                  let arguments = arguments(of: pid) else { return nil }
            return RustDeskProcess(pid: pid, arguments: arguments)
        }
    }

    /// 进程启动的时刻（内核记的）；读不到为 nil
    static func start(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 命令行：KERN_PROCARGS2 先给 argc，再是执行文件路径、若干 0 填充，然后 argc 个以 0 结尾的参数。
    /// 只能读同一个用户的进程：`--server` 与 `--cm` 都以登录用户跑，读得到
    private static func arguments(of pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
