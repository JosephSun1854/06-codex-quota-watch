#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../QuotaWatch.psm1') -Force -DisableNameChecking
$temp = Join-Path ([IO.Path]::GetTempPath()) ('quota-watch-tests-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temp) | Out-Null
$script:passed = 0
function Check($Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function Equal($Actual, $Expected) { if ($Actual -ne $Expected) { throw "Expected [$Expected], got [$Actual]" } }
function Throws([scriptblock]$Body) {
    $thrown = $false
    try { & $Body | Out-Null } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected an exception.' }
}
function Usage($Used = 20, $Reset = 2000, $Weekly = 10) {
    @{ ordinaryUsageAllowed = $true; rateLimitsByLimitId = @{ codex = @{
        primary = @{ usedPercent = $Used; resetsAt = $Reset; windowDurationMins = 300 }
        secondary = @{ usedPercent = $Weekly; resetsAt = 9000 } } } }
}
function Failure {
    @{ thread = @{ status = @{ type = 'idle' } }; latestTurn = @{
        id = 'fake-turn'; status = 'failed'; error = @{ codexErrorInfo = 'usageLimitExceeded' } } }
}
try {
    Check 'HH:mm rolls to the next day when needed' {
        $now = [DateTimeOffset]::Parse('2030-01-02T20:00:00+08:00')
        Equal (Resolve-ResetTime '05:46' $now) ([DateTimeOffset]::Parse('2030-01-03T05:46:00+08:00').ToUnixTimeSeconds())
        Equal (Resolve-ResetTime '20:30' $now) ($now.AddMinutes(30).ToUnixTimeSeconds())
    }
    Check 'absolute times require a timezone and must be future' {
        $now = [DateTimeOffset]::Parse('2030-01-02T20:00:00+08:00')
        Throws { Resolve-ResetTime '2030-01-02 23:00' $now }
        Throws { Resolve-ResetTime '2029-01-01T00:00:00Z' $now }
        Throws { Resolve-ResetTime '25:00' $now }
    }
    Check 'task matching is exact and uses the latest name for each id' {
        $one = [guid]::NewGuid().ToString(); $two = [guid]::NewGuid().ToString()
        $rows = @(@{id=$one;thread_name='Old'}, @{id=$one;thread_name='New'}, @{id=$two;thread_name='New extra'})
        [IO.File]::WriteAllLines((Join-Path $temp 'session_index.jsonl'), [string[]]@($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }))
        $matched = @(Resolve-TaskNames @('New','New') $temp)
        Equal $matched.Count 1; Equal $matched[0].id $one
        Throws { Resolve-TaskNames @('Old') $temp }
        Throws { Resolve-TaskNames @('Ne') $temp }
    }
    Check 'ambiguous task names are rejected' {
        $row = @{id=[guid]::NewGuid().ToString();thread_name='New'} | ConvertTo-Json -Compress
        [IO.File]::AppendAllText((Join-Path $temp 'session_index.jsonl'), "$row`n")
        Throws { Resolve-TaskNames @('New') $temp }
    }
    Check 'standalone setup finds a separate controller and rejects self-monitoring' {
        $index=Get-LocalTaskIndex $temp
        $one=@($index.Values)[0]
        $controller=Resolve-Controller @(@{id=$one.id}) $temp $one.id
        Equal ($controller -ne $one.id) $true
        Equal (Resolve-Controller @(@{id=$one.id}) $temp $controller) $controller
        Throws { Resolve-Controller @($index.Values) $temp '' }
    }
    Check 'missing quota never means unused quota' {
        Equal (Get-Quota @{}).ready $false
        $u = Usage; $u.rateLimitsByLimitId.codex.primary.usedPercent = $null
        Equal (Get-Quota $u).ready $false
    }
    Check 'an unrelated legacy bucket cannot override the named bucket' {
        $u = Usage 100; $u.rateLimits = (Usage 0).rateLimitsByLimitId.codex
        Equal (Get-Quota $u).ready $false
        $u.rateLimitsByLimitId = @{ other = $u.rateLimits }
        Equal (Get-Quota $u).ready $false
    }
    Check 'weekly and account-wide blocks prevent resuming' {
        Equal (Get-Quota (Usage 0 2000 100)).ready $false
        $u = Usage; $u.ordinaryUsageAllowed = $false
        Equal (Get-Quota $u).ready $false
    }
    Check 'only structured quota failures qualify, not transient 429s or prose' {
        Equal (Test-QuotaFailure (Failure)) $true
        $s = Failure; $s.latestTurn.error = @{ message = 'HTTP 429 rateLimitExceeded' }
        Equal (Test-QuotaFailure $s) $false
        $s.latestTurn.error = @{ message = 'Please log in' }; Equal (Test-QuotaFailure $s) $false
        $s.latestAssistantMessage = @{text='quota exhausted'}; Equal (Test-QuotaFailure $s) $false
    }
    Check 'completed, interrupted and active work is never auto-resumed' {
        foreach ($status in @('completed','interrupted','inProgress')) {
            $s = Failure; $s.latestTurn.status = $status; Equal (Test-QuotaFailure $s) $false
        }
    }
    Check 'resuming requires reset, a buffer and fresh quota proof' {
        $ts = @{pending=@{turnId='fake-turn';reset=1000;used=100}}
        Equal (Test-ResumeReady $ts (Failure) (Get-Quota (Usage)) 1100) $true
        Equal (Test-ResumeReady $ts (Failure) (Get-Quota (Usage)) 1059) $false
        Equal (Test-ResumeReady $ts (Failure) (Get-Quota (Usage 100 1000)) 1100) $false
        Equal (Test-ResumeReady $ts (Failure) (Get-Quota (Usage 0 1000)) 1100) $true
    }
    Check 'a manual restart or an already-used reset suppresses duplicate sends' {
        $ts = @{pending=@{turnId='fake-turn';reset=1000;used=100};lastResumeWindow=2000}
        Equal (Test-ResumeReady $ts (Failure) (Get-Quota (Usage)) 1100) $false
        $ts.Remove('lastResumeWindow'); $s = Failure; $s.latestTurn.id='new-turn'
        Equal (Test-ResumeReady $ts $s (Get-Quota (Usage)) 1100) $false
    }
    Check 'approval or user-input waits block delivery' {
        $s = Failure; $s.thread.status.activeFlags = @('waitingForUserInput')
        Equal (Test-Attention $s) $true
        Equal (Test-ResumeReady @{pending=@{turnId='fake-turn';reset=1000;used=100}} $s (Get-Quota (Usage)) 1100) $false
    }
    Check 'delivery journal is saved before sending and survives lost acknowledgements' {
        $module = Get-Module QuotaWatch
        & $module {
            param($Dir)
            $original = ${function:Invoke-AppTool}
            try {
                $script:testCalls = 0
                function script:Invoke-AppTool {
                    param($Config, $Name, $Arguments)
                    $script:testCalls++
                    $saved = Read-JsonFile (Join-Path $script:testDir 'state.json')
                    if ($saved.tasks.fake.outbox.test.status -ne 'sending') { throw 'Write-ahead journal missing.' }
                    throw 'Simulated lost acknowledgement.'
                }
                $script:testDir = $Dir
                $ts = @{outbox=@{}}; $state = @{enabled=$true;tasks=@{fake=$ts}}
                $task = @{id='fake';title='Synthetic task'}
                if (Send-Once @{} $state $task $ts 'test' 'test' $Dir) { throw 'Unexpected success.' }
                if (Send-Once @{} $state $task $ts 'test' 'test' $Dir) { throw 'Duplicate delivery.' }
                if ($script:testCalls -ne 1 -or -not $ts.hold) { throw 'Deduplication failed.' }
                Write-Atomic (Join-Path $Dir 'STOP') 'paused'
                $null = Send-Once @{} $state $task $ts 'other' 'test' $Dir
                if ($script:testCalls -ne 1) { throw 'Pause did not stop sending.' }
            } finally { Set-Item Function:script:Invoke-AppTool $original }
        } $temp
    }
    Check 'pipe reads preserve Unicode and reject truncation' {
        $message = [Text.Encoding]::UTF8.GetBytes('继续任务')
        $stream = [IO.MemoryStream]::new($message)
        try { Equal ([Text.Encoding]::UTF8.GetString((Read-PipeBytes $stream $message.Length ([Threading.CancellationToken]::None)))) '继续任务' }
        finally { $stream.Dispose() }
        $stream = [IO.MemoryStream]::new([byte[]](1,2))
        try { Throws { Read-PipeBytes $stream 4 ([Threading.CancellationToken]::None) } } finally { $stream.Dispose() }
    }
    Check 'full tick resumes a quota failure once, after rechecking the live state' {
        & (Get-Module QuotaWatch) {
            param($Dir)
            $originalApp = ${function:Invoke-AppTool}; $originalSnapshot = ${function:Get-TaskSnapshot}
            try {
                $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
                $script:mockCalls = 0; $script:mockSends = 0
                $script:mockQuota = @{rateLimitsByLimitId=@{codex=@{primary=@{usedPercent=10;resetsAt=$now+18000;windowDurationMins=300}}}}
                $script:mockSnapshot = @{thread=@{status=@{type='idle'}};latestTurn=@{id='mock';status='failed';completedAt=$now-300;error=@{codexErrorInfo='usageLimitExceeded'}}}
                function script:Invoke-AppTool {
                    param($Config, $Name, $Arguments)
                    if ($Name -eq 'get_usage_limits') { $script:mockCalls++; return $script:mockQuota }
                    if ($Name -eq 'send_message_to_thread') { $script:mockSends++; return @{accepted=$true} }
                    throw 'Unexpected tool call'
                }
                function script:Get-TaskSnapshot { param($Config,$Task); $script:mockSnapshot }
                $cfg=@{tasks=@(@{id='synthetic';title='Demo'});firstReset=$now-120}
                $state=@{enabled=$true;tasks=@{};quota=@{reset=$now-120;used=100}}
                Invoke-WatchTick $cfg $state $Dir
                if ($script:mockSends -ne 1 -or $script:mockCalls -ne 2 -or $state.tasks.synthetic.resumes -ne 1) { throw 'Quota resumption or fresh verification failed.' }
                Invoke-WatchTick $cfg $state $Dir
                if ($script:mockSends -ne 1) { throw 'Repeated tick duplicated the message.' }
            } finally {
                Set-Item Function:script:Invoke-AppTool $originalApp
                Set-Item Function:script:Get-TaskSnapshot $originalSnapshot
            }
        } (Join-Path $temp 'resume-case')
    }
    Check 'full tick preserves a normal completion and does not retry it' {
        & (Get-Module QuotaWatch) {
            param($Dir)
            $originalApp=${function:Invoke-AppTool}; $originalSnapshot=${function:Get-TaskSnapshot}
            try {
                function script:Invoke-AppTool {
                    param($Config,$Name,$Arguments)
                    if ($Name -ne 'get_usage_limits') { throw 'Unexpected send for a completed turn' }
                    @{rateLimitsByLimitId=@{codex=@{primary=@{usedPercent=5;resetsAt=9999999999;windowDurationMins=300}}}}
                }
                function script:Get-TaskSnapshot { param($Config,$Task); @{thread=@{status=@{type='idle'}};latestTurn=@{id='done';status='completed'}} }
                $cfg=@{tasks=@(@{id='synthetic';title='Demo'});firstReset=1}
                $state=@{enabled=$true;tasks=@{}}
                Invoke-WatchTick $cfg $state $Dir
                if ($state.tasks.synthetic.note -notlike 'Normal completion*') { throw 'Completed turn handling failed.' }
                if ($state.tasks.synthetic.outbox.Count -ne 0) { throw 'Unexpected queued message.' }
            } finally {
                Set-Item Function:script:Invoke-AppTool $originalApp
                Set-Item Function:script:Get-TaskSnapshot $originalSnapshot
            }
        } (Join-Path $temp 'completed-case')
    }
    Check 'paused and expired ticks do not even connect to the app' {
        & (Get-Module QuotaWatch) {
            param($Dir)
            $original=${function:Invoke-AppTool}
            try {
                function script:Invoke-AppTool { throw 'Must not connect' }
                $state=@{enabled=$false;tasks=@{}}
                Invoke-WatchTick @{} $state $Dir
                if ($state.lastCheck) { throw 'Paused tick was executed' }
                $state.enabled=$true; $state.expires=1
                Invoke-WatchTick @{} $state $Dir
                if ($state.enabled -or $state.error -notlike 'Monitoring expired*') { throw 'Expiry did not disable monitoring' }
            } finally { Set-Item Function:script:Invoke-AppTool $original }
        } (Join-Path $temp 'paused-case')
    }
    Check 'distribution contains no personal config or hard-coded task IDs' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../QuotaWatch.psm1'), (Join-Path $PSScriptRoot '../Watch-Quota.ps1') -Raw
        Equal ([bool]($source -match 'E:[/\\]ChatGPT|C:[/\\]Users[/\\]|01a0f8|gh[pousr]_[A-Za-z0-9]{20}')) $false
    }
    Write-Output "$script:passed tests passed. No live messages were sent."
} finally {
    # Only remove the temporary directory created above, after checking its resolved boundary.
    $resolved = [IO.Path]::GetFullPath($temp)
    $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('quota-watch-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
