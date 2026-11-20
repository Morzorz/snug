import Foundation
import Testing
@testable import SnugCore

@Suite("远控端口 RemoteAdapter")
struct RemoteAdapterTests {
    @Test("注入事件来源：只认可执行文件名完全对上的进程；读不到路径、同名目录、名字只是前缀都不认")
    func injectedEventSource() {
        let source = fakeRemote.injector
        #expect(source.matches(executablePath: "/Applications/甲.app/Contents/Helpers/JiaServer", userData: 0))
        #expect(source.matches(executablePath: "JiaServer", userData: 42))
        #expect(!source.matches(executablePath: "", userData: 0))
        #expect(!source.matches(executablePath: "/Applications/甲.app/Contents/MacOS/甲", userData: 0))
        #expect(!source.matches(executablePath: "/tmp/JiaServer/helper", userData: 0))
        #expect(!source.matches(executablePath: "/Applications/甲.app/Contents/Helpers/JiaServerAgent", userData: 0))
        #expect(!source.matches(executablePath: "/Applications/甲.app/Contents/Helpers/jiaserver", userData: 0))
    }

    @Test("注入事件来源再带 userData：值对上才认，值不对、路径不对都不认；没指定的不看这个字段")
    func injectedEventSourceUserData() {
        let tagged = InjectedEventSource(executableName: "YiServer", userData: 100)
        #expect(tagged.matches(executablePath: "/Applications/乙.app/Contents/MacOS/YiServer", userData: 100))
        #expect(!tagged.matches(executablePath: "/Applications/乙.app/Contents/MacOS/YiServer", userData: 0))
        #expect(!tagged.matches(executablePath: "/Applications/乙.app/Contents/MacOS/YiServer", userData: 101))
        // Snug 自己补发的事件写的是 'SNUG'，不能认成远控注入的
        #expect(!tagged.matches(executablePath: "/Applications/乙.app/Contents/MacOS/YiServer", userData: 0x534E_5547))
        #expect(!tagged.matches(executablePath: "/Applications/乙.app/Contents/MacOS/Yi", userData: 100))
        #expect(!tagged.matches(executablePath: "", userData: 100))
        // 0 是明确指定的值，和「不看这个字段」不是一回事
        #expect(InjectedEventSource(executableName: "YiServer", userData: 0).matches(executablePath: "YiServer", userData: 0))
        #expect(!InjectedEventSource(executableName: "YiServer", userData: 0).matches(executablePath: "YiServer", userData: 100))
    }

    @Test("写进日志的写法：带 userData 的标出来，不带的只有程序名")
    func injectedEventSourceDescription() {
        #expect(InjectedEventSource(executableName: "JiaServer").description == "JiaServer")
        #expect(InjectedEventSource(executableName: "YiServer", userData: 100).description == "YiServer（eventSourceUserData 100）")
    }
}
