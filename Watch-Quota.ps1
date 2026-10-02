#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Configure','Start','Pause','Status','Doctor','Tick','Install')][string]$Action = 'Status',
    [string[]]$TaskName,
    [string]$ResetAt,
    [string]$CodexHome = $env:CODEX_HOME,
    [string]$DataDir = (Join-Path $PSScriptRoot '.local')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'QuotaWatch.psm1') -Force -DisableNameChecking
if (-not $IsWindows) { throw 'This version supports Windows desktop only.' }
$DataDir = [IO.Path]::GetFullPath($DataDir)
[IO.Directory]::CreateDirectory($DataDir) | Out-Null
$taskId = 'Codex-Quota-Watch-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($DataDir.ToLowerInvariant()))).Substring(0,12)
$configPath = Join-Path $DataDir 'config.json'
$statePath = Join-Path $DataDir 'state.json'
$stopPath = Join-Path $DataDir 'STOP'

function Install-Schedule {
    $shell = (Get-Process -Id $PID).Path
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -File "' + $PSCommandPath + '" -Action Tick -DataDir "' + $DataDir + '"'
    $job = New-ScheduledTaskAction -Execute $shell -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskId -Action $job -Trigger $trigger -Settings $settings -Principal $principal -Description 'Check selected local Codex tasks every five minutes.' -Force | Out-Null
    Disable-ScheduledTask -TaskName $taskId | Out-Null
}

# Stop is effective immediately, even when another tick owns the state file lock.
if ($Action -eq 'Pause') {
    Write-Atomic $stopPath ([DateTimeOffset]::Now.ToString('o'))
    if (Get-ScheduledTask -TaskName $taskId -ErrorAction SilentlyContinue) { Disable-ScheduledTask -TaskName $taskId | Out-Null }
}
$lock = $null
try {
    try { $lock = [IO.File]::Open((Join-Path $DataDir 'watch.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        if ($Action -in @('Tick','Pause')) { Write-Output 'Another check is finishing. A pause marker takes effect before the next send.'; exit 0 }
        throw 'A check is running. Please retry after it finishes.'
    }
    $config = Read-JsonFile $configPath
    $state = Read-JsonFile $statePath
    if (-not $state.tasks) { $state.tasks = @{} }
    switch ($Action) {
        'Configure' {
            if (-not $TaskName -or -not $ResetAt) { throw 'Provide -TaskName and -ResetAt.' }
            if ($state.enabled -and -not (Test-Path -LiteralPath $stopPath)) { throw 'Pause monitoring before changing its configuration.' }
            if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
            $tasks = @(Resolve-TaskNames $TaskName $CodexHome)
            $config = @{ version = 2; tasks = $tasks; firstReset = (Resolve-ResetTime $ResetAt)
                callerThreadId = (Resolve-Controller $tasks $CodexHome)
                appId = 'OpenAI.Codex_2p2nqsd0c76g0!App' }
            Write-Atomic $configPath $config
            $state = @{ enabled = $false; tasks = @{} }
            Write-Atomic $stopPath 'Configured; waiting for Start.'
            foreach ($task in $tasks) { Save-Checkpoint $task @{} $DataDir }
            Install-Schedule
            Write-Output 'Configured and installed in PAUSED state. Use -Action Doctor, then -Action Start when ready.'
        }
        'Install' { if (-not $config.tasks) { throw 'Configure first.' }; Install-Schedule; Write-Atomic $stopPath 'Installed paused.'; $state.enabled = $false }
        'Start' {
            if (-not $config.tasks) { throw 'Configure first.' }
            Install-Schedule
            if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
            $state.enabled = $true
            $state.expires = [DateTimeOffset]::Now.AddDays(7).ToUnixTimeSeconds()
            Write-Atomic $statePath $state
            Enable-ScheduledTask -TaskName $taskId | Out-Null
            Invoke-WatchTick $config $state $DataDir
        }
        'Pause' { $state.enabled = $false; Write-Output 'Paused. Checkpoints are preserved.' }
        'Tick' { if (-not $config.tasks) { throw 'Configure first.' }; Invoke-WatchTick $config $state $DataDir }
        'Doctor' {
            if (-not $config.tasks) { throw 'Configure first.' }
            $preview = ($state | ConvertTo-Json -Depth 30) | ConvertFrom-Json -AsHashtable
            Invoke-WatchTick $config $preview $DataDir -DryRun
            $preview | ConvertTo-Json -Depth 10
            if ($preview.error -or @($preview.tasks.Values | Where-Object { $_.note -notlike 'Turn:*' }).Count) { throw 'Read-only check failed; see diagnostic output.' }
            return
        }
    }
    if ($Action -ne 'Status') { Write-Atomic $statePath $state }
    $active = $state.enabled -and -not (Test-Path -LiteralPath $stopPath)
    $status = @{ enabled = [bool]$active; intervalMinutes = 5; scheduledTask = $taskId
        lastCheck = $state.lastCheck; quota = $state.quota; error = $state.error
        tasks = @($config.tasks | ForEach-Object { @{ title = $_.title; status = $state.tasks[$_.id].note; resumes = $state.tasks[$_.id].resumes } }) }
    Write-Atomic (Join-Path $DataDir 'status.json') $status
    $status | ConvertTo-Json -Depth 10
} finally { if ($lock) { $lock.Dispose() } }
