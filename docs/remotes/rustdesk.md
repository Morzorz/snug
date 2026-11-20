# RustDesk 适配

RustDesk 的适配器，接入方式见 [接入新的远控](README.md)，核心怎么判定连接见 [工作原理](../how-it-works.md#连接判定)。
可行性、取证与未验证项见 [RustDesk 适配可行性](../remote-adapter/research/rustdesk.md)（1.5.3 本机实测 + tag 1.5.3 源码）。

| 位置 | 内容 |
| :--- | :--- |
| `Sources/Remotes/RustDesk/Logic`（`RemoteRustDesk`） | 身份 `RustDeskRemote`、日志解析 `RustDeskLogParser`、信号与折叠 `RustDeskSignals` / `RustDeskSessionState`、自检判定 `RustDeskCheck` |
| `Sources/Remotes/RustDesk/System`（`RemoteRustDeskSystem`） | 适配器 `RustDeskRemoteAdapter`、跟随日志 `RustDeskLogWatcher`、进程 `RustDeskProcesses`、诊断 `RustDeskDump` 与 `RustDeskCheckRun` |
| `Tests/Remotes/RustDesk`（`RemoteRustDeskTests`） | 解析与信号的测试，夹具 `Fixtures/`（1.4.9、1.5.3 各一次真实会话） |

## 身份

| 项 | 值 |
| :--- | :--- |
| 日志名 | `RustDesk`（日志写「检测到 RustDesk 连入」，命令行写 `rustdesk`） |
| 界面名 | RustDesk |
| 自家 App | `com.carriez.rustdesk`（1.5.3 实测，全小写），不出现在 App 资源库里 |
| 注入事件的进程 | `RustDesk`：界面、`--server`、`--cm` 是同一个可执行文件，只是启动参数不同；注入由 `--server` 做，事件源上写死 `eventSourceUserData=100`（enigo），手势按「程序名 + 这个值」认 |

> **`eventSourceUserData` 写在事件源上，不是写在事件上。** 从远控事件拷贝出来的那份改这个字段不生效（读回来还是 100），
> 所以 Snug 补发的点击必须用自己的 `CGEventSource`（源上带 `'SNUG'` 记号）重建，并从 HID 层投递。
> 反过来，直接改拷贝的字段会把补发事件原样带回自己的监听、被当成远控的新点击，吞掉再补发、死循环——2026-11-20 真机踩到过，
> 症状是「手势一开所有点击失效、同一坐标每秒 5 次」，见 [可行性](../remote-adapter/research/rustdesk.md#11-落地2026-11-20)。

## 信号

一路信号：RustDesk 自己写的日志文件 `~/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log`（`--server` 进程一份，按天轮转）。
不读界面、不查进程表：日志里三样都有，少一路信号少一处失效点。

| 观测 | 日志行（级别） |
| :--- | :--- |
| 在场 | `#<conn> Connection opened from <地址:端口>.`（DEBUG）；兜底是推流那一路：`new video service: monitor<N>`（INFO） |
| 控制端 | 连入行里的地址:端口（RustDesk 不写控制端的设备名） |
| 推流屏 | `#displays=<块数>, current=<下标>, … name:<id>`（DEBUG）里的 `name`：就是 `CGDirectDisplayID`，与 `CGGetActiveDisplayList` 实测一致 |
| 断开 | `#<conn> Connection closed: <原因>`（INFO）；认得连入行时，最后一个连接断开就把推流状态一起清掉 |
| 信号快照 | `peer=203.0.113.7:63452 display=3 video=monitor1`，写进连入、断开日志；自检按同一写法读回（`RustDeskSignals.logged`），往返测试钉住两边 |

- **推流屏的写法容得下版本差异**：解析只认 `current=` 与 `name:`，中间当自由文本（1.4.9 与 1.5.3 实测都带 `width=`，但二进制里另有一份不带它的写法，不押在字段顺序上）
- **换屏**：服务端新开一路推流（`new video service: monitorN`）并带一行 `#displays`，旧的那路随后 `stop video service`；推流屏跟着最后开始的那一路走
- **日志按进程命名 CURRENT**：RustDesk 重启（文件换了 inode）或文件被清空时从头再读、状态重来；首次从头读整个文件，等于回看这次 `--server` 启动以来的会话
- **不拿进程判在场**：`--cm` 会话结束后不一定马上退（`--server` 只在退出时清理子进程），只用来在诊断里列

## 兼容自检

RustDesk 更新后，先用手机照常连一次（切到 Snug 的屏），再运行 `scripts/snug remote-check rustdesk`。

- **核对项**：版本（对照上次核对的版本）；`--server` 进程；`server` 日志读得到、认得出连入/断开/推流开始与停止；Snug 记到的远程与日志里的连入行对得上几次、快照能否读回；推过哪些屏、其中有没有 Snug 的屏；注入是否仍走 enigo（决定 `eventSourceUserData=100` 还成不成立）
- **判定**：位于 `RemoteRustDesk` 的 `RustDeskCheck`，日志按正式运行的解析与状态回放；Snug 日志的摘要位于 `SnugCore/Remote/SnugLogDigest`，只摘归 RustDesk 的远程
- **取证材料**：`~/Library/Logs/Snug-rustdesk-check/`，每次覆盖：报告、`--server` 日志、这段时间的 Snug 日志、当前屏幕与进程、包与注入模块的情况
- **核对完成**：报告无问题且手机实测无误后，将 `RustDeskCheck.verifiedVersion` 改为新版本
- **范围**：只读日志、进程与包，不操作 RustDesk；触控、工具栏遮挡靠手机实测

## 与 UU 不同的地方

- 信号是**文件**不是系统日志流：`RustDeskLogWatcher` 直接增量读文件，不起 `log stream` 子进程，也不需要辅助功能权限读界面
- 控制端只能到地址:端口，没有设备名
- `--server` 长期驻留、注入与界面同一个可执行文件，所以注入事件靠 `userData` 区分（UU 是独立的 `UURemoteServer`）
- 显示列表在服务端会随屏幕增减广播给客户端（源码 `display_sync`），RustDesk 不必像 UU 那样「切走再切回」；真机确认前不写进文档

## 留在共用代码里的 UU 实测值（RustDesk 沿用，未重测）

- 屏幕比例的让位（竖屏上下各 91 点、横屏左右 82+72 点，`ScreenFit`）、平板右上让开 50 点（`TouchStyle`）
- 新连接从主屏开始推流（`ScreenPlan` 的主屏常驻依据）：RustDesk 同向，日志里 `current=0` 就是主屏
- 断开防抖 1.5 秒、自扰静默期 5 秒（`ConnectionTracker`）
- 手势只接管鼠标左键（`TouchEvents`）
