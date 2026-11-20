# RustDesk 适配可行性

> 2026-11-20 · 结论先给：**能接，而且属于最省的一类**——端口四项全部装得下，共用代码只动一处（注入事件按 `eventSourceUserData` 认）。
>
> 取证范围：本机 `/Applications/RustDesk.app`（**1.5.3**，2026-11-09 构建）、2026-11-20 10:07 的一次真实被控会话（1.4.9 时期，升级前存档）、`rustdesk/rustdesk` 的 **1.5.3** 标签源码（master 的 `Cargo.toml` version 即 1.5.3）。源码结论与装机版本同版；标「实测」的取自本机日志、本机显示器与 1.5.3 二进制里的格式串。
>
> 接入步骤以 [接入新的远控](../../remotes/README.md) 为准，本文只回答「装不装得下、要改什么、怎么验」。

## 1. 结论

- **三条关键事实都与 UU 同向**，适配层当初为 RustDesk 留的判断成立：
  1. 新连接从**主屏**开始推流（`get_primary_2` → primary index，实测 `current=0` 为内置主屏）；
  2. 换屏时服务端**新开一路推流**，日志里带 `name:<CGDirectDisplayID>`，与 `CGGetActiveDisplayList` 实测对得上；
  3. 注入的鼠标事件带固定 `eventSourceUserData = 100`，比 UU 的「按进程名」更精确。
- **共用代码只改一处**：`InjectedEventSource` 加一个可选的 `userData`，`TouchEvents` 读原始事件的 `.eventSourceUserData`。其余（连接时序、主屏策略、屏幕比例、资源库排除、日志摘要）不用动。
- **新增代码量按 UU 的量级估**：纯逻辑约 250 行、系统层约 200 行、测试约 250 行，加两份日志夹具。**1.5–2 个工作日**（含一次真机联调）。
- **三条未验证项必须真机**：注入事件的来源进程号、客户端能否选到「连上后才新建」的屏、手机端工具栏压掉多少画面。验证方法见第 8 节。

## 2. 本机事实（2026-11-20）

| 项 | 值 |
| :--- | :--- |
| Bundle | `com.carriez.rustdesk`（**全小写**，`Info.plist` 实测）；版本 **1.5.3**；最低系统 12.3；arm64；Developer ID 签名（HZF9JMC8YN） |
| 可执行文件 | `Contents/MacOS/RustDesk`（引导）+ `Frameworks/liblibrustdesk.dylib`（31.5 MB 主体）+ `Contents/MacOS/service`（10 MB） |
| 常驻进程 | launchd `/Library/LaunchDaemons/com.carriez.RustDesk_service.plist`（root、KeepAlive）→ `service` → `RustDesk --server`（登录用户，长期驻留）→ 每次连入再起 `RustDesk --cm` |
| 日志 | `~/Library/Logs/RustDesk/`：根目录（界面进程）、`server/`、`cm/`、`check-hwcodec-config/`；每进程一份 `RustDesk_rCURRENT.log`，文件名带该进程的启动时刻（如 `cm/RustDesk_r2026-11-03_19-26-43.log`） |
| 配置 | `~/Library/Preferences/com.carriez.RustDesk/{RustDesk.toml, RustDesk2.toml, RustDesk_local.toml, peers/}`；本机服务端 `home.morzorz.com:21116`（自建） |
| 显示器 | `id=1` 内置 1512×982 点（3024×1964 像素，主屏）；`id=3` 外接 1920×1080 |

一次真实会话（`server/RustDesk_rCURRENT.log`，1.4.9 存档，节选）：

```
10:07:36.517 DEBUG [src/server/connection.rs:1455] #642 Connection opened from 100.81.16.29:63452.
10:07:36.577 DEBUG [src/server/video_service.rs:426] #displays=2, current=0, origin: (0, 0), width=3024, height=1964, ..., name:1
10:07:36.581 DEBUG [src/server/connection.rs:6312] Start cm
10:07:44.206 DEBUG [src/server/video_service.rs:426] #displays=2, current=1, origin: (1512, -35), width=1920, height=1080, ..., name:3
10:07:44.259 INFO  [src/server/video_service.rs:921] stop video service: monitor0
10:08:03.263 INFO  [src/server/connection.rs:5146] #642 Connection closed: Peer close
```

`name:1` / `name:3` 与本机 `CGGetActiveDisplayList` 的 `CGDirectDisplayID` 逐个一致，`current` 是列表下标，`width/height` 是像素尺寸。

**格式会漂，解析不押在字段顺序上**：1.5.3 二进制里存在一份不带 `width=` 的 `#displays=` 格式串，但 1.5.3 的真实会话仍然打出
`#displays=2, current=0, origin: (0, 0), width=3024, height=1964, cpus=14/14, name:1`（2026-11-20 15:33 实测，见第 11 节）——
先前按二进制片段判「1.5.3 去掉了 width」，是把另一条日志语句的片段当成了它，已纠正。结论不变：解析只认 `current=` 与 `name:`，中间当自由文本。
其余措辞（`Connection opened from `、`Connection closed: `、`new video service: `、`stop video service: `、`Start cm`、cm 日志的 `Got new connection` / `cm ipc connection closed from request`）在 1.5.3 二进制里逐条都在。

## 3. 源码事实（tag 1.5.3）

| 事实 | 位置 |
| :--- | :--- |
| `--cm` 是**独立进程**，由 `--server` 拉起（`run_me(vec!["--cm"])`），日志打 `Start cm` | `src/server/connection.rs`（master 与 1.5.3 同版；行号随合并漂移，不进解析） |
| 注入走 enigo；所有注入事件都写 `EVENT_SOURCE_USER_DATA = 100`，再 `post(HID)` | `libs/enigo/src/macos/macos_impl.rs:45`（`ENIGO_INPUT_EXTRA_VALUE = 100`）、`:168-169` |
| 显示列表在登录（连入）时快照，中途变化另行广播给客户端 | `src/server/display_service.rs`：`update_get_sync_displays_on_login`、`SyncDisplaysInfo.check_changed`、`get_update_sync_displays` |
| 起始屏 = primary index（主屏） | 同上 `get_primary_2`、`normalize_primary_display_idx` |
| 协议已有换屏 / 列屏 / 改分辨率 / 跟随当前屏 / 虚拟屏开关 | 1.5.3 二进制含 `misc.capture_displays`、`misc.switch_display`、`misc.change_display_resolution`、`misc.follow_current_display`、`misc.toggle_virtual_display` |

设计记录里按「RustDesk 1.5.3 源码」写的两条判断，装机 1.5.3 已逐条复核：`eventSourceUserData` 那条成立（值为 100）、「界面与服务同一可执行文件」成立（`RustDesk` 带 `--server`／`--cm` 两个身份）。

## 4. 信号映射

三路信号全部来自**日志文件**（不读界面、不查进程表），照 UU 的形状合成一份 `RemoteObservation`：

| 观测 | 取法 | 对应日志（级别） |
| :--- | :--- | :--- |
| 在场 | 出现连入行且尚未闭合 | `#N Connection opened from <ip>:<port>`（DEBUG）；兜底 `peer info supported_encoding`（INFO）、`new video service: monitorN`（INFO） |
| 控制端 | 连入行的 IP | 同上，报 `100.81.16.29`；RustDesk 不在日志里写控制端设备名 |
| 推流屏 | 最近一条 `#displays=… name:<id>` 与 `new video service: monitorN` 配对；只认 `name:` 与 `current=`，中间当自由文本（1.5.3 去掉了 `width=`） | `video_service.rs` 的 `#displays=`（DEBUG）、`new video service:` / `stop video service:`（INFO） |
| 断开 | 闭合行 | `#N Connection closed: <原因>`（INFO） |
| 信号快照 | 自拼 | `conn=642 peer=100.81.16.29:63452 display=3 video=monitor1`（写法进日志、进自检，往返测试钉住） |

用候选正则回放今天的真实日志（`/tmp` 一次性脚本，未入库），起止与换屏都对上：

```
10:07:36.517 OPEN  #642 from 100.81.16.29:63452
10:07:36.577 DISP  count=2 current=0 px=3024x1964 displayID=1
10:07:44.206 DISP  count=2 current=1 px=1920x1080 displayID=3
10:07:44.259 VIDEO stop monitor0
10:08:03.263 CLOSE #642 Peer close
```

推流屏那条改成只认 `#displays=(\d+), current=(\d+),.*name:(\d+)` 之后，1.4.9（带 `width=`）与 1.5.3（不带）两种写法用同一条正则都能认出来。

## 5. 要改的共用代码

| 位置 | 改什么 | 为什么 |
| :--- | :--- | :--- |
| `SnugCore/Remote/RemoteAdapter.swift` | `InjectedEventSource` 加 `userData: Int64?`；`matches(executablePath:userData:)` | RustDesk 的 `--cm`、`--server` 与主界面**同一可执行文件**（`RustDesk`），只按路径认无法区分；而 enigo 给所有注入事件写死 `100` |
| `SnugSystem/TouchEvents.swift` | `InjectedEvents` 读 `.eventSourceUserData` 一起交判断；`isReplay` 仍先判（补发事件写的 `'SNUG'` 与 `100` 不冲突） | 同上；判函数在核心，可测 |
| `Tests/SnugCoreTests/Remote/RemoteAdapterTests.swift` | 正例、反例、边界（路径对但 userData 错、userData 对但路径错、nil） | 门禁要求核心可测 |
| `Tests/RemoteContractTests/*` | driver 增 `injectorUserData`；断言「本机事件、Snug 补发事件不认」照旧 | 契约清单随接口一起长 |

**不用改**：`ConnectionTracker` 的 1.5s / 5s 时序（RustDesk 关连接干净，实测 0 抖动）、`ScreenPlan` 的主屏常驻（起始屏就是主屏）、`AppList` 排除（走 `identity.bundleIDs`）、`SnugLogDigest`（12.1 已按归属分流）。

**可能改**：`ScreenFit.clientToolbarInset` / `clientLandscapeInsets`、`TouchStyle` 平板右上让位——都按 UU 实测标定。RustDesk 手机端工具栏位置不同，实测后若需要不同的让位，只有两条路：改共用值（同时影响 UU，要在 `uu.md` 记差异），或承认做不到按家给（建屏早于知道哪家来连，设为主屏的屏更是常驻）。先实测，再决定。

## 6. 目标与目录

照 UU 的形状，三个目标、路径写死在 `Package.swift`：

```
Sources/Remotes/RustDesk/Logic    → RemoteRustDesk
    RustDeskRemote      身份：日志名 "RustDesk"，界面名 "RustDesk"，
                        bundleIDs {com.carriez.rustdesk}（1.5.3 实测即此，全小写），
                        injector: 可执行文件 RustDesk + userData 100
    RustDeskLogParser   一行 → 一个事件（opened/closed/display/videoStart/videoStop）
    RustDeskSessionState 事件折叠成 present/controllers/streamedDisplay ＋ 快照文本
    RustDeskCheck       兼容自检的判定
Sources/Remotes/RustDesk/System   → RemoteRustDeskSystem
    RustDeskLogTail     跟随 server/ 与 cm/ 的 RustDesk_rCURRENT.log（轮转、截断、退避重启、启动回看）
    RustDeskRemoteAdapter
    RustDeskDump / RustDeskCheckRun
Tests/Remotes/RustDesk            → RemoteRustDeskTests（夹具：今天两份日志，IP 脱敏）
Tests/RemoteContractTests/Drivers/RustDeskDriver.swift
```

日志名用 `RustDesk`（命令行 `rustdesk`），与 UU 的 `UU` 不冲突；门禁按目录名 `RustDesk` 查核心、系统层、核心测试——`TouchTranslator.swift:7`、`TouchEvents.swift:13` 各有一处提及，都在整行注释里，门禁放行（已核）。

## 7. 实施步骤（每步一个 commit，每步 `scripts/snug check`）

1. **核心：注入事件按 userData 认**（先写测试、看它红）。`InjectedEventSource` 加可选字段，`TouchEvents` 读原始事件字段，契约驱动补 `injectorUserData`。UU 传 nil，行为逐字不变。
2. **纯逻辑：解析与状态**。`RustDeskLogParser` + `RustDeskSessionState` + `RustDeskRemote`，夹具用 1.4.9 与 1.5.3 各一次真实会话（IP 打码），单测覆盖：连入即在场、断开即缺席、换屏跟 `name:`、日志截断时不误判、DEBUG 行缺失时降级到 INFO。
3. **系统层：跟随日志 + 适配器**。`RustDeskLogTail` 照 `CaptureLogWatcher` 的形状（回看 4 小时、文件被轮转/清空时重开、退避重启、只认当前 server 进程写的行）；`RustDeskRemoteAdapter` 每拍合成观测；`RustDeskDump` 打原始信号。
4. **登记与契约**。`Snug/App/Remotes.swift` 加一行 `Entry(adapter: RustDeskRemoteAdapter.self, dump: RustDeskDump.run, check: RustDeskCheckRun.run(hours:))`；`RustDeskDriver` 进 `drivers`。此时门禁才全绿。
5. **兼容自检**。`RustDeskCheck` 核对：RustDesk 版本、`--server` 进程、日志里能否认出连入/断开/推流屏、注入事件字段是否仍为 100、当前屏列表；`--check-remote rustdesk` 与 `scripts/snug remote-check rustdesk` 同 UU 口径。
6. **文档与记忆**。`docs/remotes/rustdesk.md`（身份、信号、自检、与 UU 不同的实测值）、README 三语「开发」一节、`.memory/` 一条。

## 8. 验收

```
scripts/snug check                                   # 门禁全绿；用例数只增不减（当前 498 个 @Test，参数化的按驱动展开）
swift build && "$(swift build --show-bin-path)/Snug" --dump-remote rustdesk
scripts/snug install && scripts/snug remote-check rustdesk
```

真机矩阵（手机端 RustDesk 客户端，自建服务器）：

| # | 场景 | 期望 | 取证 |
| :--- | :--- | :--- | :--- |
| 1 | 空闲 | 不建屏，日志无连入 | `Snug.log` 无「检测到 RustDesk 连入」 |
| 2 | 连入（Snug 屏设为主屏） | 直接进入 Snug 屏，不手动选屏 | 日志：连入 → 会话开始 → 建屏 |
| 3 | 连入（未设主屏） | 建屏后客户端显示列表里能选到新屏 | 客户端截图 + `#displays=` 行 |
| 4 | 换屏 | 快照 `display=` 跟随；手势范围跟着走 | 日志两行快照对比 |
| 5 | 断开 → 15 秒内重连 | 同一次远程，屏不撤不建 | 日志：断开 → 重连上 |
| 6 | 断开 → 等满 15 秒 | 撤屏、窗口还原 | 日志：会话结束 |
| 7 | 手机点击 / 拖动 / 长按右键 / 双指滚动 | 与 UU 一致 | 真机操作 |
| 8 | Snug 屏上的窗口、资源库 | 铺满、字号放大；资源库无 RustDesk | 真机 |
| 9 | 升级后的首次会话（1.5.3） | `server/`、`cm/` 照旧在写；`#displays=` 行能认出 `name:` | tail 两个文件 + 快照 |
| 10 | 没给辅助功能权限 | 不建屏、不翻译手势，菜单栏提示照旧 | 系统设置里取消授权 |

日志级别没有用户开关（1.4.9、1.5.3 实测默认打 DEBUG），「只有 INFO 行时还能认」用夹具模拟，不占真机项。

### 未验证项与验证方法

- **注入事件的来源**：用下面的脚本在真机远程时抓一次，确认 `pid` 是 `--server` 进程、`userData == 100`、坐标落在 Snug 屏上。

  ```swift
  // swift injectpeek.swift —— 远程时按住拖动，看输出
  import CoreGraphics
  import Foundation

  let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
  let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                              eventsOfInterest: mask, callback: { _, type, event, _ in
      let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
      var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let n = proc_pidpath(pid, &buf, UInt32(buf.count))
      let path = n > 0 ? String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "?"
      print("type=\(type.rawValue) pid=\(pid) path=\(path) userData=\(event.getIntegerValueField(.eventSourceUserData)) at=\(event.location)")
      return Unmanaged.passUnretained(event)
  }, userInfo: nil)!
  CGEvent.tapEnable(tap: tap, enable: true)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  CFRunLoopRun()
  ```

- **客户端显示列表刷新**：连接后由 Snug 建屏，不重连，直接在客户端打开显示器菜单，看新屏在不在、能否切过去。源码会广播显示变化（第 3 节），客户端 UI 的刷新时机要实测。
- **手机端遮挡**：分别用手机竖屏、横屏、平板各连一次，量工具栏压掉的高度/宽度，与 `ScreenFit` 的 91 / 82+72 对比。

## 9. 风险与对策

| 风险 | 影响 | 对策 |
| :--- | :--- | :--- |
| 连接行是 DEBUG | 用户调高日志级别后认不出连入 | 并行认 INFO 的 `peer info` / `new video service`；快照带 `level=`；自检发现「有远程却认不出连入」报「需留意」（照 UUCheck 12.1 的做法） |
| `--cm` 进程存活久于会话 | 拿它当在场信号会误判 | **不用进程判在场**，只用日志；进程只在诊断里列 |
| 日志按进程命名 `CURRENT` | 文件被轮转、截断 | tail 跟随 inode/大小，变了重开；回看最近 4 小时 |
| 客户端显示列表不刷新 | 中途新建的屏选不到 | 主屏常驻是主路径（不依赖刷新）；刷新不可用时退回「重连一次」并在文档写明 |
| 遮挡常量按 UU 标定 | 手机端画面被工具栏压住 | 实测后调共用值并在 `uu.md` 记差异；不接受按家分支（建屏早于知道哪家来连） |
| 日志格式跨版本变化 | 解析认不出、静默失效 | 1.4.9 与 1.5.3 的 `#displays=` 都带 `width=`，但二进制里另有一份不带它的写法：解析只认 `name:`、`current=`，中间当自由文本；夹具用两版真实会话；自检把「版本 + 关键行是否还在」一起核对 |
| Bundle ID 大小写 | 资源库里漏掉 RustDesk | 按实测登记 `com.carriez.rustdesk`；旧版是否另有写法未核，遇到再补 |
| 无辅助功能权限 | 手势失效、建屏被跳过 | 现状即如此（`ScreenPlan` 无权限一块不建），文档写明 |

## 10. 不做（本次范围外）

- RustDesk 的隐私模式、多屏同推、改被控端分辨率——与 Snug 的屏管理会打架，等有人真的用再说。
- 按家调连接时序、按家给遮挡——没有实测依据前不加接口（设计记录第 5 节同结论）。
- 读 RustDesk 界面（辅助功能）——日志已经够，少一路信号少一处失效点。

## 11. 落地（2026-11-20）

按第 7 节做完第 1–5 步，与方案不同的地方：

| 项 | 方案 | 落地 | 为什么 |
| :--- | :--- | :--- | :--- |
| 跟几路日志 | `server/` 与 `cm/` 都跟 | 只跟 `server/RustDesk_rCURRENT.log` | cm 那两行（`Got new connection`、`cm ipc connection closed`）与 server 的连接行重复，多一路多一处失效点；`--cm` 进程只进诊断 |
| 契约驱动 | driver 增 `injectorUserData` | 不加，直接用 `identity.injector.userData` | 身份只有一份，驱动不必再抄；契约测试按身份里的值构造正反例 |
| 日志跟随 | `RustDeskLogTail`，回看 4 小时 | `RustDeskLogWatcher`（IO）+ `RustDeskLogAnchor`／`RustDeskLogCursor`（纯逻辑、有测试）：每拍增量读，按 inode 与长度判轮转，首次从头读整个文件 | 文件本身就是「这次 `--server` 启动以来的全部」，不需要 `log show` 回看，也就不起子进程；读哪儿、怎么切行抽成纯值类型，测试盖得住 |
| 日志级别兜底 | 计划里列了「调高级别时降级」 | 状态机直接以「推流那一路」作正面证据（`new video service` 是 INFO） | 实测没有用户可调的级别开关；兜底做成数据模型的一部分，顺带覆盖「连入行漏掉」的其它情形 |

验收（本机 RustDesk 1.5.3，2026-11-20 15:2x）：

- `scripts/snug check`：门禁全过，`swift test` **498 例全绿**（`@Test` 478 → 498：RustDesk 18 个——解析 8、切行与跟随 2、信号 8；核心适配层 +2；契约测试按两家驱动展开）
- `Snug --dump-remote rustdesk`：读到 1.5.3 的日志 24 行、认出 `--server`（pid 7333）与界面进程、两块屏；无会话时「在场：否」
- `Snug --check-remote rustdesk 4`：版本 1.5.3、`--server` 在跑、日志可读、注入仍走 enigo（`libs/enigo/src/macos/macos_impl.rs` 在）4 项 ✅；「连接行」1 项 ⚠️——升级后还没连过，属预期。取证材料落在 `~/Library/Logs/Snug-rustdesk-check/`
- 真机矩阵（第 8 节 10 项）与三条未验证项**尚未做**：需要一台手机连一次。升级后第一次会话的日志落地后，替换 `Tests/Remotes/RustDesk/Fixtures/server-session-1.5.3.log` 的合成样本
- 对外文案未动：README 三语里「目前专注 UU远程，暂不自行适配其他远控软件」与「开发」一节的措辞，等真机验证过再由主人定稿

### 11.1 真机踩到的两个问题（2026-11-20）

1. **`--cm` 进程不用于判在场**（已在落地时按此写）：会话结束后它不一定马上退。
2. **补发事件带不动记号，导致自吞死循环**：Snug 把远控事件「拷贝 + `setIntegerValueField(.eventSourceUserData, 'SNUG')`」后补发，
   但 `eventSourceUserData` 是 `CGEventSource` 的属性——拷贝保留的是 RustDesk 的源（值 100），改字段读回来仍是 100。
   于是补发事件回到自己的监听里被当成「RustDesk 的新点击」，吞掉再补发：症状是手势一开所有点击失效、同一坐标每秒约 5 次刷屏，
   手势关掉则一切正常（说明 RustDesk 的坐标与注入本身没问题）。
   **修法**：补发用 `CGEventSource(stateID: .combinedSessionState)` 新建、`source.userData = 'SNUG'`，再按原事件的类型、
   位置、点击计数重建点击；投递从 `.cgSessionEventTap` 改到 `.cghidEventTap`（真实输入的入口）。修完日志里补发事件是
   `uid=1397642567`，回到自己监听时判为补发、直接放行，循环消失，点击落到手机上按的位置。

诊断过程（可复用的手法）：外部只读监听（`CGEventTap` listenOnly）看「事件有没有到、带什么 uid」，
加上 Snug 自己在监听里按 `到达/到达+补发` 两行打点，一次定位了「谁发的、发到哪、有没有回来」。
