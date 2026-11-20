// 远控适配层的端口：核心只认这几样，不认识具体是哪家远控。每家远控一个适配器（Sources/Remotes），在 App 层登记（Snug/App/Remotes.swift）。
// 适配器每拍交一份中性的观测；连接判定、会话、建屏、手势翻译都在核心，各家共用
import Foundation

/// 一家远控的身份
public struct RemoteIdentity: Equatable, Sendable {
    /// 写进日志和命令行参数的名字（「检测到 UU 连入」）。日志措辞靠它保持不变，自检也按它认
    public let logName: String
    /// 界面上的名字（「在 UU远程 中选择 Snug 的屏」）
    public let displayName: String
    /// 这家远控自己的 App：不出现在 App 资源库里（把遥控器放到 Snug 的屏上没有意义，退了它远程就断了）
    public let bundleIDs: Set<String>
    /// 被远程时注入鼠标事件的进程：手势翻译只接管它发来的
    public let injector: InjectedEventSource

    public init(logName: String, displayName: String, bundleIDs: Set<String>, injector: InjectedEventSource) {
        self.logName = logName
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.injector = injector
    }
}

/// 认哪个进程注入的事件：按来源进程的可执行文件名认，本机的触控板、鼠标不是它发的。
/// 界面与被远程时注入的进程是同一个可执行文件时（同一份程序带不同启动参数），再加 `userData`：
/// 有的远控给每个注入事件写一个固定的 eventSourceUserData，光看进程名分不出是谁发的
public struct InjectedEventSource: Equatable, Sendable, CustomStringConvertible {
    public let executableName: String
    /// 事件自带的 eventSourceUserData 必须等于它；nil = 不看这一个字段
    public let userData: Int64?

    public init(executableName: String, userData: Int64? = nil) {
        self.executableName = executableName
        self.userData = userData
    }

    /// executablePath：事件来源进程的可执行文件路径，读不到时为空串；userData：事件自带的 eventSourceUserData。
    /// 补发的事件也被这里判过：调用方先放行自己补发的（TouchEvents.isReplay），再到这儿
    public func matches(executablePath: String, userData: Int64) -> Bool {
        guard (executablePath as NSString).lastPathComponent == executableName else { return false }
        guard let expected = self.userData else { return true }
        return expected == userData
    }

    /// 写进日志的写法：手势翻译开启时列出接管谁发来的，排查「手势没反应」先看这里
    public var description: String {
        userData.map { "\(executableName)（eventSourceUserData \($0)）" } ?? executableName
    }
}

/// 一拍里对一家远控的观测
public struct RemoteObservation: Equatable, Sendable {
    /// 有人在远程的正面证据。读不到、没认出都不算缺席：适配器只在确有证据时报在场
    public var present: Bool
    /// 认出的控制端，按适配器给的顺序。空 = 没认出，不代表没人
    public var controllers: [String]
    /// 此刻在推的屏。nil = 不知道，不代表没在推（AppState.watching 把 nil 当作「在看」）
    public var streamedDisplay: DisplayID?
    /// 写进连入、断开日志的信号快照：排查误判时才知道是哪一路信号在变
    public var evidence: String

    public init(present: Bool, controllers: [String], streamedDisplay: DisplayID?, evidence: String) {
        self.present = present
        self.controllers = controllers
        self.streamedDisplay = streamedDisplay
        self.evidence = evidence
    }
}

/// 一家远控这一拍的观测，带上是哪家
public struct RemoteReading: Equatable, Sendable {
    public let remote: RemoteIdentity
    public let observation: RemoteObservation

    public init(remote: RemoteIdentity, observation: RemoteObservation) {
        self.remote = remote
        self.observation = observation
    }
}

/// 一家远控的适配器：盯着这家远控在本机留下的痕迹（进程、日志、界面），每拍交一份观测
@MainActor
public protocol RemoteAdapter: AnyObject {
    /// 身份是这家远控的，不是某个实例的：登记处、诊断命令、运行中的适配器都从这里取，只有一份
    static var identity: RemoteIdentity { get }
    init()
    /// App 开始监控时调一次
    func start()
    /// 退出收尾前调一次
    func stop()
    /// 每拍调一次。wallClock 是墙钟（系统日志的时间戳是墙钟）；会话层另用单调时钟
    func sample(wallClock: Date) -> RemoteObservation
}

extension RemoteAdapter {
    public var identity: RemoteIdentity { Self.identity }
}
