# 06 · Codex Quota Watch · 额度续接助手

给定**任务名称**和**下次 5 小时额度重置时间**，监控 Windows 上的 ChatGPT / Codex 工作聊天，保存续接材料，并在额度恢复后继续确实因额度失败的任务。

**PowerShell 7.2+ · 无第三方模块 · 每 5 分钟检查 · 默认配置后暂停 · MIT**

> 实验性、社区维护的本地工具，不是 OpenAI 官方产品。仅支持提供兼容本地工具桥接的 Windows 桌面版本；普通 ChatGPT 网页、旧版 ChatGPT 应用、云端任务、macOS 和 Linux 不在当前支持范围内。它等待额度自然恢复，不绕过额度限制。

## 它解决什么问题

长任务遇到额度耗尽时，可能来不及整理下一次继续工作的指令。本工具会在工作期间保存最近可见进度，并提醒原任务维护检查点；额度恢复后，确认原任务仍停在额度失败状态，再发送“继续”和续接说明。

- 用**精确任务名称**匹配本地聊天 ID，支持多个任务；重名会报错，不猜测目标。
- 用量达到 **80%** 时提醒正在运行的任务写进度。启动后首次发现正在工作的任务，也会提醒建立检查点。
- 每 **5 分钟**读取用量和任务状态。检查本身不调用语言模型；发送的进度提醒和继续指令会消耗原任务的模型额度。
- 重置时间之后再留 **60 秒缓冲**，核实实际额度已经恢复。后续读取真实重置时间，不机械地每隔 5 小时重发。
- 正常结束、被用户停止、等待登录或审批、普通网络错误，不自动重启。
- 发送前保存去重记录；发送结果不明确时暂停该任务的自动发送，避免重复启动。

5 小时指账号的额度窗口，不是某个任务保证可运行 5 小时。周额度耗尽也会阻止续接。

## 快速开始

需要 Windows、PowerShell 7.2 或更新版本，以及已登录且支持本地工作聊天的 ChatGPT / Codex 桌面应用。无需 Node.js、Python 或 API Key。

在 PowerShell 7 中运行：

```powershell
git clone https://github.com/JosephSun1854/06-codex-quota-watch.git
cd 06-codex-quota-watch

# 只需提供任务名称和下一次重置时间；配置后保持暂停。
./Watch-Quota.ps1 -Action Configure -TaskName '整理研究资料' -ResetAt '14:30'

# 只读检查应用连接、额度和任务状态，不发送消息。
./Watch-Quota.ps1 -Action Doctor

# 你准备好后再启动。
./Watch-Quota.ps1 -Action Start
```

不想输入命令时，可以双击 `quota-watch.cmd`，按提示逐行填写任务名称和重置时间。**填写配置不会启动监控。**之后在该文件夹运行 `quota-watch.cmd Start` 启动，`quota-watch.cmd Pause` 暂停。

如果以 ZIP 形式下载后被 Windows 阻止执行，先在下载的 ZIP 属性中解除阻止，再解压；无需修改全局执行策略。

### 多任务、日期和目录

```powershell
./Watch-Quota.ps1 -Action Configure `
  -TaskName '整理研究资料', '完善演示文稿' `
  -ResetAt '2030-01-02T14:30:00+08:00'
```

- `HH:mm` 按这台电脑的本地时间解释；今天该时间已过，则表示明天。跨时区使用时，推荐带 `+08:00` 等时区偏移的完整日期。
- 完整日期必须在未来；它是首次续接的最早时间，脚本还会检查实时额度。
- 默认从 `CODEX_HOME` 环境变量或用户目录下的 `.codex` 读取任务索引。自定义数据目录时，可增加 `-CodexHome 'D:/MyCodexHome'`。
- 仅匹配本机 `session_index.jsonl` 中的精确名称。找不到时，先在桌面应用中打开目标任务；重名时先在应用中改成不同名称。
- 应用禁止聊天监控自身，因此脚本会自动选取另一个现有本地聊天作为控制上下文，优先使用你配置助手时所在的聊天。不会向这个控制聊天发送消息；不要把它同时选作监控目标。如果所有现有聊天都被选中，需先在应用中新建一个助手聊天，再配置。
- 可用 `-DataDir 'D:/PrivateQuotaWatch'` 更换私有数据目录；**之后每个命令都要使用同一个目录**。调度任务也与这个目录绑定。

## 日常操作

| 命令参数 | 作用 |
| --- | --- |
| `-Action Configure -TaskName ... -ResetAt ...` | 保存配置、创建暂停的定时任务；已有监控需要先暂停 |
| `-Action Start` | 启用定时任务并立即检查一次；保留去重记录 |
| `-Action Pause` | 暂停发送和定时检查，保留文件；不停止原任务 |
| `-Action Status` | 查看启用状态、用量及各任务结果 |
| `-Action Doctor` | 只读验证连接与所选任务，不发消息 |
| `-Action Install` | 重装定时任务，保持暂停 |

任务计划程序中的名称以 `Codex-Quota-Watch-` 开头，每 **5 分钟**触发一次，不同时运行多个检查进程。**不主动唤醒睡眠中的电脑**；需要电脑开机、网络可用，且 Windows 用户已登录。应用可以最小化；若已经关闭，并有到期的待续接任务，会尝试重新打开应用，在下次检查时继续处理。关机、注销或睡眠期间不能保证准点执行。

开始一次监控后默认有效 **7 天**，每个目标任务最多自动续接 **20 次**。到期后停止发送；`Start` 可以续期，计数和发送记录仍保留。如需重新配置，先暂停并核实旧消息的发送情况。

## 本地文件与隐私

所有运行数据默认写入 `.local/`，该目录已加入 `.gitignore`，不进入本仓库的发布内容：

```text
.local/
  config.json                  # 你选择的任务、聊天 ID、首次重置时间
  state.json                   # 额度、待续接状态、发送去重记录
  status.json                  # 便于查看的状态
  STOP                         # 暂停标记
  checkpoints/<thread-id>/
    resume.txt                 # 不依赖剩余额度的通用续接指令
    snapshot.md                # 最近可见的助手消息及轮次状态
    AI-progress.md             # 原任务收到提醒后自行写入；不一定已存在
```

脚本不会覆盖 `AI-progress.md`，也不会读取登录凭据或上传任务内容到 GitHub。**`.gitignore` 不能保护你手动打包上传的整个目录**；分享时只发源码，不要附上 `.local/`、聊天快照或自己的配置。

## 边界与故障处理

- **不能保证额度耗尽前一定得到 AI 总结。**账号额度是共享的，5 分钟内也可能快速用完，提醒还可能排队。因此先保存不需要模型额度的快照和续接指令。配置后的初始快照可能还没有进度正文；运行检查后更新。
- 自动快照只包含最近可见助手消息，可能截断；完整要求仍在原聊天中。它不冒充完整摘要，不复制隐藏推理，也不保证备份所有文件。
- 检查间隔使操作最多多等待约 5 分钟；应用启动或重连可能再增加一个检查周期。
- `Doctor` 返回错误时先解决连接、版本或任务名称问题。未知额度、周额度耗尽、登录失效、权限拒绝时不会猜测可用容量。
- 状态显示 `Unconfirmed earlier delivery` 或 `Delivery uncertain` 时，先暂停并打开原聊天，确认带 `[quota-watch:...]` 标记的消息是否已送达，再决定是否重新配置。脚本不会自动重发不确定的消息。
- 暂停不会撤回已经发送或正在传输的消息，也不会中断原任务的工作。
- 切换 Windows 账号、移动程序/数据目录或升级应用后，建议重新 `Install`、`Doctor`，确认后才 `Start`。

## 实现与验证

实现统一使用 PowerShell，利用 Windows 命名管道和任务计划程序，不安装额外服务、不模拟鼠标键盘。`QuotaWatch.psm1` 负责读取、状态判断和受限发送；`Watch-Quota.ps1` 负责配置与调度。

额度字段参考 [OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server)。当前实际连接的是**桌面应用随附的本地工具桥接**，不是承诺稳定的公共 API；协议可能随应用更新变化。已在 Windows 桌面版本 **26.928.3736.0** 上验证读取额度与目标聊天，其他版本需自行运行 `Doctor`。没有通过升级/降级权限绕过应用检查。

测试不启动真实任务、不发送真实消息：

```powershell
./tests/Test-QuotaWatch.ps1
```

测试覆盖名称匹配与重名拒绝、跨天时间、缺失额度、周额度阻塞、用户中断、重置缓冲、重复发送、发送结果不明及暂停标记。GitHub Actions 在 Windows 上运行同一套离线测试。真实耗尽额度再恢复的完整过程仍需要在实际触发时验证；不把模拟测试当成生产保证。

## English

An experimental Windows-only quota supervisor for compatible ChatGPT/Codex desktop work chats. Configure exact local task names and the next quota reset time, then explicitly start monitoring. It checks every five minutes, saves local checkpoints, and resumes only confirmed usage-limit failures after capacity recovers. Requires PowerShell 7.2+, no extra modules or API key. Private runtime data stays in `.local/`. The desktop bridge is version-dependent; run `Doctor` before enabling. Licensed under MIT.
