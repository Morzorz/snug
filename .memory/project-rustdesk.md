---
name: project-rustdesk
description: RustDesk 适配（11-20 落地，代码与自检已过）：信号只有一份日志、注入按 userData 100 认、日志格式 1.4.9/1.5.3 有差；真机三条未验证、README 立场待主人定
metadata:
  node_type: memory
  type: project
  modified: 2026-11-20T07:25:00.000Z
---

- **11-20 落地**（主人：「开搞」）：`Sources/Remotes/RustDesk/{Logic,System}`、`Tests/Remotes/RustDesk`、契约驱动、`Remotes.swift` 登记。方案、取证、落地差异在 `docs/remote-adapter/research/rustdesk.md`（第 1–11 节），适配说明 `docs/remotes/rustdesk.md`。`scripts/snug check` 全绿，496 例
- **信号只有一路**：`~/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log`（连入/断开/推流/`#displays=… name:<CGDirectDisplayID>`）。`--cm` 进程活过会话（`--server` 只在退出时清子进程），**不能拿来判在场**
- **注入按「程序名 RustDesk + eventSourceUserData=100」认**（enigo 写死）。核心的 `InjectedEventSource` 因此多了可选 `userData`；UU 传 nil，行为不变
- **日志格式会漂**：1.4.9 与 1.5.3 实测都带 `width=`，但二进制里另有一份不带它的写法（曾据此误判，15:33 真会话纠正）。解析只认 `current=` 与 `name:`，中间当自由文本（`RustDeskLogParser`）；夹具两版真实会话各一份
- **11-20 真机验过**：注入事件来源 `--server` 进程、`eventSourceUserData=100`、连上后新建的屏客户端能选到、点按/拖动/长按都落到手机上按的位置
- **踩到的坑（已修，别再踩）**：`eventSourceUserData` 是 `CGEventSource` 的属性，拷贝远控事件改字段不生效（读回还是 100）；补发必须用自己的 CGEventSource（源上带 `'SNUG'`）重建点击，并从 `.cghidEventTap` 投递。否则补发事件回到自己监听、被当成远控新点击 → 自吞死循环（症状：手势一开点击全失效、同一坐标每秒 5 次；手势关则正常）
- **仍未测**：手机端工具栏遮挡量（`ScreenFit` 仍用 UU 的 91 / 82+72）、App 资源库与窗口铺满的观感、多屏同推
- **待主人定**：README 三语的「目前专注 UU远程，暂不自行适配其他远控软件」与「开发」一节措辞，等真机验证过再改；`docs/remotes/README.md` 已按两家更新

**Why:** 接第二家最容易失手的两处是信号口径（进程 vs 日志）和日志格式随版本漂移。
**How to apply:** 动 RustDesk 相关先跑 `scripts/snug remote-check rustdesk`；RustDesk 升级后先看自检的「连接行」「注入来源」两项；换夹具时 1.4.9 与 1.5.3 两种 `#displays=` 写法都要留。
