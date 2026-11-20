// --check-remote rustdesk [小时]：RustDesk 兼容自检（scripts/snug remote-check rustdesk 调）。收集事实交给 RustDeskCheck 判定、打出报告，
// 并把原始材料写进 ~/Library/Logs/Snug-rustdesk-check/（每次覆盖）：RustDesk 的 --server 日志、这段时间的 Snug 日志、当前屏幕与进程。
// 哪项不对直接看材料，不用再一步步复现。只读：不点 RustDesk、不碰屏幕
import AppKit
import RemoteRustDesk
import SnugCore
import SnugSystem

@MainActor
package enum RustDeskCheckRun {
    static let evidence = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Snug-rustdesk-check")

    package static func run(hours: Int) -> Int32 {
        let now = Date()
        let since = now.addingTimeInterval(-TimeInterval(hours) * 3600)
        var files: [String: String] = [:]

        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RustDeskRemote.bundleID)
        let version = bundle.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        let modulePresent = bundle.map { bundleContains($0, RustDeskCheck.injectorModule) } ?? false
        files["rustdesk-bundle.txt"] = (bundle.map { "RustDesk：\($0.path)（\(version ?? "版本未知")）" } ?? "RustDesk：没装")
            + "\n\(RustDeskCheck.injectorModule)：\(modulePresent ? "在" : "不在")"

        let processes = RustDeskProcesses.list()
        let server = processes.first { $0.isServer }.map { RustDeskCheck.Server(pid: $0.pid, start: RustDeskProcesses.start(of: $0.pid)) }
        files["processes.txt"] = processes.isEmpty
            ? "没有 RustDesk 在运行"
            : processes.map { "pid \($0.pid) \($0.arguments.first ?? "") \($0.describeArguments)" }.joined(separator: "\n")

        let logURL = RustDeskLogWatcher.standardURL
        let serverLines = readLines(logURL)
        let window = serverLines.map { recent($0, since: server?.start.flatMap { $0 > since ? $0 : nil } ?? since) }
        files["rustdesk-server.log"] = window?.joined(separator: "\n") ?? "读不到 \(logURL.path)"

        let snugLines = readSnugLog()
        files["snug.log"] = SnugLogDigest.recent(snugLines, since: since).joined(separator: "\n")
        files["displays.txt"] = RustDeskDump.displayLines().joined(separator: "\n")

        let onlineSnug = Set((Screens.online() ?? []).filter { CGDisplayVendorNumber($0) == ScreenSpec.vendorID })
        let facts = RustDeskCheck.Facts(hours: hours, since: since, version: version, server: server,
                                        connectionManagerRunning: processes.contains(where: \.isConnectionManager),
                                        serverLog: window, logPath: logURL.path, injectorModulePresent: modulePresent,
                                        snugLog: snugLines.map(String.init), onlineSnugDisplays: onlineSnug)
        let items = RustDeskCheck.evaluate(facts)
        let report = RustDeskCheck.report(items, hours: hours, at: now)
        files["report.txt"] = report
        print(report)
        print("")
        print(writeEvidence(files))
        return items.contains { $0.status == .fail } ? 1 : 0
    }

    // MARK: 收集

    /// since 之后的日志行；认不出时间的行跟着上一行走（多行的报错）
    static func recent(_ lines: [String], since: Date) -> [String] {
        var keep = false
        return lines.filter { line in
            if let date = RustDeskLogParser.stamp(line) { keep = date >= since }
            return keep
        }
    }

    /// 包里有没有哪个 Mach-O 带着这段字节（注入那条路的模块路径）
    private static func bundleContains(_ bundle: URL, _ needle: String) -> Bool {
        let data = Data(needle.utf8)
        let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let content = try? Data(contentsOf: url, options: .alwaysMapped), isMachO(content) else { continue }
            if content.range(of: data) != nil { return true }
        }
        return false
    }

    private static func isMachO(_ data: Data) -> Bool {
        let magics: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]]
        return data.count >= 4 && magics.contains { data.prefix(4).elementsEqual($0) }
    }

    private static func readLines(_ url: URL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 滚动过的旧日志在前（见 FileLogSink），读不到的跳过
    private static func readSnugLog() -> [Substring] {
        let current = SnugPaths.standard.logFile
        let rotated = current.deletingLastPathComponent().appendingPathComponent(current.lastPathComponent + ".1")
        return [rotated, current].flatMap { url -> [Substring] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n")
        }
    }

    /// 整个目录换成这次的材料；写不进去时说明原因（报告已经打出来了，不因此失败）
    private static func writeEvidence(_ files: [String: String]) -> String {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: evidence.path) { try fm.removeItem(at: evidence) }
            try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
            for (name, content) in files {
                try Data(content.utf8).write(to: evidence.appendingPathComponent(name))
            }
            return "取证材料：\(evidence.path)（\(files.keys.sorted().joined(separator: "、"))）"
        } catch {
            return "取证材料写不进 \(evidence.path)：\(error)"
        }
    }
}
