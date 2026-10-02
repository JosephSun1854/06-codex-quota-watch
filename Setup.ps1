#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Write-Host 'Codex Quota Watch / 额度续接助手'
Write-Host 'Enter exact task names, one per line. Leave an empty line when finished.'
$names = @()
while ($name = Read-Host 'Task name') { $names += $name }
if (-not $names.Count) { throw 'At least one task is required.' }
$reset = Read-Host 'Next reset (HH:mm in local time, or ISO date with timezone)'
& (Join-Path $PSScriptRoot 'Watch-Quota.ps1') -Action Configure -TaskName $names -ResetAt $reset
& (Join-Path $PSScriptRoot 'Watch-Quota.ps1') -Action Doctor
Write-Host 'Configuration saved in PAUSED state. Run Watch-Quota.ps1 -Action Start to activate.'
