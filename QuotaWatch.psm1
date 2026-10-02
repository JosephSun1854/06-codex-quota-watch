#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$script:Connection = $null

function Read-JsonFile($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

function Write-Atomic($Path, $Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 30 }
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $Path, $true)
}

function Resolve-ResetTime([string]$Text, [DateTimeOffset]$Now = [DateTimeOffset]::Now) {
    if ($Text -match '^([01]\d|2[0-3]):([0-5]\d)$') {
        $time = [TimeSpan]::ParseExact($Text, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
        $result = [DateTimeOffset]::new($Now.Date.Add($time), $Now.Offset)
        if ($result -le $Now) { $result = $result.AddDays(1) }
    } else {
        # Full timestamps require an explicit UTC offset so schedules survive timezone ambiguity.
        if ($Text -notmatch '(Z|[+-]\d{2}:\d{2})$') { throw 'Use HH:mm or a full ISO date with timezone, e.g. 2030-01-02T14:30:00+08:00.' }
        $result = [DateTimeOffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture)
        if ($result -le $Now) { throw 'Reset time must be in the future.' }
    }
    $result.ToUnixTimeSeconds()
}

function Get-LocalTaskIndex([string]$CodexHome) {
    $index = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $index)) { throw 'Local session index not found. Open the task in the desktop app, or set -CodexHome.' }
    $latest = @{}
    foreach ($line in [IO.File]::ReadLines($index)) {
        if (-not $line.Trim()) { continue }
        $row = $line | ConvertFrom-Json -AsHashtable
        if ($row.id -and $row.thread_name) { $latest[$row.id] = $row }
    }
    $latest
}

function Resolve-TaskNames([string[]]$Names, [string]$CodexHome) {
    $latest = Get-LocalTaskIndex $CodexHome
    foreach ($name in ($Names | Select-Object -Unique)) {
        $matches = @($latest.Values | Where-Object { $_.thread_name -ceq $name })
        if ($matches.Count -eq 0) { throw "No exact local task name: $name" }
        if ($matches.Count -gt 1) { throw "Duplicate task name: $name. Rename the tasks in the app so each name is unique." }
        $row = $matches[0]
        [guid]::Parse($row.id) | Out-Null
        @{ id = $row.id; title = $name }
    }
}

function Resolve-Controller($Tasks, [string]$CodexHome, [string]$Preferred = $env:CODEX_THREAD_ID) {
    $index = Get-LocalTaskIndex $CodexHome
    if ($Preferred -and $index.ContainsKey($Preferred) -and $Preferred -notin $Tasks.id) { return $Preferred }
    $other = @($index.Values | Where-Object { $_.id -notin $Tasks.id } | Sort-Object updated_at -Descending)
    if (-not $other.Count) { throw 'The desktop app requires a separate existing local chat as controller. Create a helper chat in the app, then configure again.' }
    [guid]::Parse($other[0].id) | Out-Null
    $other[0].id
}

function Read-PipeBytes($Pipe, [int]$Count, $Token) {
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $n = $Pipe.ReadAsync($buffer, $offset, $Count - $offset, $Token).GetAwaiter().GetResult()
        if ($n -eq 0) { throw 'Desktop pipe closed before returning a complete response.' }
        $offset += $n
    }
    ,$buffer
}

function Invoke-PipeRequest($PipeName, $Method, $Params, [int]$TimeoutMs = 20000) {
    $name = $PipeName -replace '^\\\\\.\\pipe\\', ''
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $cancel = [Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        $pipe.ConnectAsync([Math]::Min(2000, $TimeoutMs), $cancel.Token).GetAwaiter().GetResult()
        $body = [Text.Encoding]::UTF8.GetBytes((@{ jsonrpc = '2.0'; id = 1; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 30))
        $header = [BitConverter]::GetBytes([uint32]$body.Length)
        $pipe.WriteAsync($header, 0, 4, $cancel.Token).GetAwaiter().GetResult()
        $pipe.WriteAsync($body, 0, $body.Length, $cancel.Token).GetAwaiter().GetResult()
        $size = [BitConverter]::ToUInt32((Read-PipeBytes $pipe 4 $cancel.Token), 0)
        if ($size -gt 8388608) { throw 'Desktop response exceeds 8 MiB.' }
        $response = [Text.Encoding]::UTF8.GetString((Read-PipeBytes $pipe $size $cancel.Token)) | ConvertFrom-Json -AsHashtable
        if ($response.error) { throw $response.error.message }
        $response.result
    } finally { $pipe.Dispose(); $cancel.Dispose() }
}

function Connect-Desktop {
    if ($script:Connection) { return }
    $pipes = @($env:CODEX_APP_TOOLS_PIPE_PATH) + @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'codex-browser-use-' })
    foreach ($pipe in ($pipes | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $catalog = Invoke-PipeRequest $pipe 'tools/list' @{ threadStartKind = 'all' } 2500
            $tools = @{}
            foreach ($tool in $catalog.tools) { $tools[$tool.name] = $tool.namespace }
            if ($tools.get_usage_limits -and $tools.wait_threads -and $tools.send_message_to_thread) {
                $script:Connection = @{ pipe = $pipe; tools = $tools }; return
            }
        } catch { continue }
    }
    throw 'Desktop app tools are unavailable. Open the compatible ChatGPT/Codex desktop app.'
}

function Invoke-AppTool($Config, [string]$Name, $Arguments = @{}) {
    if ($Name -notin @('get_usage_limits', 'wait_threads', 'send_message_to_thread')) { throw 'Tool not allowed.' }
    if ($Name -eq 'send_message_to_thread' -and $Arguments.threadId -notin $Config.tasks.id) { throw 'Task is outside the configured allowlist.' }
    if ($Name -eq 'send_message_to_thread' -and $Arguments.threadId -eq $Config.callerThreadId) { throw 'Controller cannot be a monitored task.' }
    Connect-Desktop
    $reply = Invoke-PipeRequest $script:Connection.pipe 'tools/call' @{
        namespace = $script:Connection.tools[$Name]; tool = $Name; arguments = $Arguments
        callerSource = 'codex'; threadId = $Config.callerThreadId
        callId = "quota-watch-$([guid]::NewGuid())"; turnId = "quota-watch-$([guid]::NewGuid())"
    }
    $text = ($reply.contentItems | Where-Object type -eq 'inputText' | ForEach-Object text) -join "`n"
    if (-not $reply.success) { throw "Desktop tool rejected the request: $text" }
    try { $text | ConvertFrom-Json -AsHashtable } catch { @{ text = $text } }
}

function Get-TaskSnapshot($Config, $Task) {
    $result = Invoke-AppTool $Config 'wait_threads' @{ targets = @(@{ threadId = $Task.id; hostId = 'local' }); timeoutMs = 0 }
    $poll = @($result.polls | Where-Object { $_.thread.id -eq $Task.id })
    if ($poll.Count -ne 1) { throw "Cannot read the selected local task: $($Task.title)" }
    $poll[0]
}

function Get-Quota($Response) {
    $bucket = if ($Response.rateLimitsByLimitId) { $Response.rateLimitsByLimitId.codex } else { $Response.rateLimits }
    $p = $bucket.primary; $s = $bucket.secondary
    $known = $null -ne $p.usedPercent -and $null -ne $p.resetsAt -and $p.windowDurationMins -eq 300
    $blocked = $Response.ordinaryUsageAllowed -eq $false -or $bucket.spendControlReached -eq $true -or
        [bool]$bucket.rateLimitReachedType -or $p.usedPercent -ge 100 -or $s.usedPercent -ge 100
    @{ known = $known; ready = $known -and -not $blocked; used = $p.usedPercent; reset = $p.resetsAt
       weeklyUsed = $s.usedPercent; weeklyReset = $s.resetsAt }
}

function Test-Active($Snapshot) { $Snapshot.thread.status.type -eq 'active' -or $Snapshot.latestTurn.status -eq 'inProgress' }
function Test-Attention($Snapshot) { ($Snapshot.thread.status.activeFlags | ConvertTo-Json -Compress) -match 'waitingForApproval|waitingForUserInput|needsInput' }
function Test-QuotaFailure($Snapshot) {
    $errorText = ConvertTo-Json -InputObject $Snapshot.latestTurn.error -Depth 15 -Compress
    # Plain HTTP 429 / rateLimitExceeded can mean transient request throttling, not the five-hour quota.
    -not (Test-Active $Snapshot) -and $Snapshot.latestTurn.status -eq 'failed' -and
        $errorText -match 'usage[_\s-]*limit|usageLimitExceeded|quota[_\s-]*(exceed|exhaust)|exceeded.{0,30}quota|用量.{0,8}(上限|耗尽)|额度.{0,8}(上限|耗尽)'
}

function Test-ResumeReady($TaskState, $Snapshot, $Quota, [long]$Now) {
    $p = $TaskState.pending
    $proof = $Quota.reset -gt $p.reset -or ($null -ne $p.used -and $Quota.used -lt $p.used)
    [bool]($p -and $Snapshot.latestTurn.id -eq $p.turnId -and (Test-QuotaFailure $Snapshot) -and
        -not (Test-Attention $Snapshot) -and $Quota.ready -and $Now -ge ($p.reset + 60) -and $proof -and
        $TaskState.lastResumeWindow -ne $Quota.reset)
}

function Get-ResumePrompt($Task, $DataDir) {
    $dir = Join-Path $DataDir "checkpoints/$($Task.id)"
    @"
继续。请从本聊天实际未完成的步骤继续，遵守最新用户指示和已有授权范围，保留当前模型设置。
先读取“$dir/AI-progress.md”（如存在）和“$dir/snapshot.md”，核对实际文件与证据，不重做已完成部分。
每完成一个主要步骤及本轮结束前更新 AI-progress.md：已完成内容及证据路径、当前步骤、剩余清单、阻碍、下一步可执行指令。
遇到登录、验证码、审批或关键资料缺失时明确说明并等待；任务完成后列出成果和核验结果并停止。不得编造结果，不新增发布、付费或提交授权。
"@
}

function Save-Checkpoint($Task, $Snapshot, $DataDir) {
    $dir = Join-Path $DataDir "checkpoints/$($Task.id)"
    Write-Atomic (Join-Path $dir 'resume.txt') (Get-ResumePrompt $Task $DataDir)
    $message = $Snapshot.latestAssistantMessage.text
    Write-Atomic (Join-Path $dir 'snapshot.md') @"
# $($Task.title)

Updated: $([DateTimeOffset]::Now.ToString('o'))
Thread: $($Task.id)
Turn status: $($Snapshot.latestTurn.status)

这是本地脚本摘录的最近可见消息，不是 AI 对整个任务的总结。完整要求以原聊天和实际成果文件为准。

$message
"@
}

function Send-Once($Config, $State, $Task, $TaskState, $Key, $Prompt, $DataDir) {
    if ((Test-Path -LiteralPath (Join-Path $DataDir 'STOP')) -or -not $State.enabled -or $TaskState.outbox.ContainsKey($Key)) { return $false }
    $entry = @{ status = 'sending'; marker = "[quota-watch:$([guid]::NewGuid())]"; at = [DateTimeOffset]::Now.ToString('o') }
    $TaskState.outbox[$Key] = $entry
    Write-Atomic (Join-Path $DataDir 'state.json') $State
    try {
        $null = Invoke-AppTool $Config 'send_message_to_thread' @{ threadId = $Task.id; hostId = 'local'; prompt = "$($entry.marker)`n$Prompt" }
        $entry.status = 'accepted'
        Write-Atomic (Join-Path $DataDir 'state.json') $State
        return $true
    } catch {
        $entry.status = 'uncertain'; $entry.error = $_.Exception.Message
        $TaskState.hold = 'Delivery uncertain. Check the original chat before reconfiguring; automatic sends are paused for this task.'
        Write-Atomic (Join-Path $DataDir 'state.json') $State
        return $false
    }
}

function Invoke-WatchTick($Config, $State, $DataDir, [switch]$DryRun) {
    if (-not $DryRun -and (-not $State.enabled -or (Test-Path -LiteralPath (Join-Path $DataDir 'STOP')))) { return }
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $State.lastCheck = [DateTimeOffset]::Now.ToString('o')
    if (-not $DryRun -and $State.expires -and $now -ge $State.expires) { $State.enabled = $false; $State.error = 'Monitoring expired after seven days.'; return }
    $previous = $State.quota
    try {
        $State.quota = Get-Quota (Invoke-AppTool $Config 'get_usage_limits')
        $State.Remove('error')
        foreach ($task in $Config.tasks) {
            if (-not $State.tasks.ContainsKey($task.id)) { $State.tasks[$task.id] = @{ outbox = @{} } }
            $ts = $State.tasks[$task.id]
            try {
                $s = Get-TaskSnapshot $Config $task; $turn = $s.latestTurn
                if (-not $DryRun) { Save-Checkpoint $task $s $DataDir }
                $ts.note = "Turn: $($turn.status)"
                if ($DryRun) { continue }
                $ts.wasActive = Test-Active $s
                # A crash after write-ahead cannot be mistaken for a fresh unsent message.
                if (@($ts.outbox.Values | Where-Object status -in @('sending', 'uncertain')).Count) { $ts.hold = 'Unconfirmed earlier delivery; inspect the original chat.' }
                if ($ts.hold) { $ts.note = $ts.hold; continue }
                if ($ts.pending -and $ts.pending.turnId -ne $turn.id) { $ts.Remove('pending') }
                if (Test-Active $s) {
                    if ((Test-Attention $s) -or -not $State.quota.ready) { continue }
                    $urgent = $State.quota.used -ge 80
                    $key = if ($urgent) { "checkpoint:$($State.quota.reset)" } else { 'checkpoint:initial' }
                    if (-not $ts.outbox.ContainsKey($key)) {
                        $fresh = Get-TaskSnapshot $Config $task
                        if (-not (Test-Active $fresh) -or (Test-Attention $fresh) -or $fresh.latestTurn.id -ne $turn.id) { continue }
                        $progress = Join-Path $DataDir "checkpoints/$($task.id)/AI-progress.md"
                        $prompt = "请在下一个安全步骤将已完成内容、证据文件绝对路径、剩余工作、阻碍和下一步续接指令写入「$progress」，以后每个主要步骤和结束前更新。保存后继续原任务，遵守最新用户指示。"
                        if ($urgent) { $prompt = '账户5小时额度已接近上限。' + $prompt }
                        $null = Send-Once $Config $State $task $ts $key $prompt $DataDir
                    }
                } elseif (Test-QuotaFailure $s) {
                    if (-not $ts.pending) {
                        $failedAt = if ($turn.completedAt) { $turn.completedAt } else { $now }
                        $candidates = @($Config.firstReset, $previous.reset, $State.quota.reset) | Where-Object { $_ -and $_ -ge ($failedAt - 60) }
                        $reset = ($candidates | Measure-Object -Minimum).Minimum
                        if (-not $reset) { $reset = $State.quota.reset }
                        # A future user-provided first reset is a not-before time.
                        if ($Config.firstReset -gt $now) { $reset = [Math]::Max($reset, $Config.firstReset) }
                        $ts.pending = @{ turnId = $turn.id; reset = $reset; used = $previous.used }
                    }
                    $ts.note = 'Quota failure: waiting for reset and fresh available quota.'
                    if (-not (Test-ResumeReady $ts $s $State.quota $now) -or $ts.resumes -ge 20) { continue }
                    $fresh = Get-TaskSnapshot $Config $task
                    $quota = Get-Quota (Invoke-AppTool $Config 'get_usage_limits')
                    if (-not (Test-ResumeReady $ts $fresh $quota ([DateTimeOffset]::Now.ToUnixTimeSeconds()))) { continue }
                    if (Send-Once $Config $State $task $ts "resume:$($turn.id)" (Get-ResumePrompt $task $DataDir) $DataDir) {
                        $ts.lastResumeWindow = $quota.reset; $ts.resumes = 1 + $ts.resumes
                        $ts.Remove('pending'); $ts.note = 'Continuation accepted by the desktop app.'
                    }
                } else { $ts.Remove('pending'); $ts.note = 'Normal completion, user stop, or other issue: no automatic restart.' }
            } catch { $ts.note = $_.Exception.Message }
        }
    } catch {
        $State.error = $_.Exception.Message
        $due = @($State.tasks.Values | Where-Object { ($_.pending -and $now -ge ($_.pending.reset + 60)) -or ($_.wasActive -and $now -ge ([Math]::Max($previous.reset, $Config.firstReset) + 60)) }).Count
        if (-not $DryRun -and $due -and ($now - ($State.lastAppLaunch ?? 0)) -ge 600) {
            $State.lastAppLaunch = $now
            Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($Config.appId)" -WindowStyle Hidden
        }
    }
}

Export-ModuleMember -Function *
