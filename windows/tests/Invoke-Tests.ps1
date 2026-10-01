#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester 5 tests in Windows PowerShell 5.1 and in PowerShell 7 (when installed), then PSScriptAnalyzer.

.EXAMPLE
    .\windows\tests\Invoke-Tests.ps1
.EXAMPLE
    .\windows\tests\Invoke-Tests.ps1 -SkipAnalyzer
#>
[CmdletBinding()]
param(
    [switch]$Inner,          # (internal) run Pester in the current engine
    [switch]$SkipAnalyzer
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Find-ModulePath {
    # Pester 5 / PSScriptAnalyzer may be installed only for PowerShell 7 (Documents\PowerShell\Modules) - look there too
    param([string]$Name, [version]$MinVersion)
    $dirs = @($env:PSModulePath -split ';') + @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'),
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'PowerShell\Modules'))
    $hits = foreach ($d in ($dirs | Where-Object { $_ } | Select-Object -Unique)) {
        Get-ChildItem -Path (Join-Path $d $Name) -Filter "$Name.psd1" -Recurse -ErrorAction SilentlyContinue
    }
    $best = $hits | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Version = [version](Split-Path (Split-Path $_.FullName) -Leaf) } } |
        Where-Object { $_.Version -ge $MinVersion } | Sort-Object Version -Descending | Select-Object -First 1
    if ($best) { return $best.Path } else { return $null }
}

if ($Inner) {
    $pester = Find-ModulePath -Name 'Pester' -MinVersion '5.0'
    if (-not $pester) { throw 'Pester 5 not found (Install-Module Pester -MinimumVersion 5.0)' }
    Import-Module $pester -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.Exit = $true
    $cfg.Output.Verbosity = 'Normal'
    Invoke-Pester -Configuration $cfg
    return
}

$failed = 0
$engines = @([pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') })
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwsh) { $engines += [pscustomobject]@{ Name = 'PowerShell 7'; Exe = $pwsh.Source } }
foreach ($e in $engines) {
    Write-Host ''
    Write-Host "===== Pester in $($e.Name) =====" -ForegroundColor Cyan
    & $e.Exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Inner
    if ($LASTEXITCODE -ne 0) { $failed++; Write-Host "$($e.Name): $LASTEXITCODE failed test(s)" -ForegroundColor Red }
}

if (-not $SkipAnalyzer) {
    Write-Host ''
    Write-Host '===== PSScriptAnalyzer =====' -ForegroundColor Cyan
    $pssa = Find-ModulePath -Name 'PSScriptAnalyzer' -MinVersion '1.20'
    if (-not $pssa) { Write-Host 'PSScriptAnalyzer not found - skipped' -ForegroundColor Yellow }
    else {
        Import-Module $pssa -Force
        $root = Split-Path $PSScriptRoot -Parent
        $res = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'install') -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
        $res | ForEach-Object { '{0}:{1} [{2}] {3}' -f (Split-Path $_.ScriptPath -Leaf), $_.Line, $_.RuleName, $_.Message }
        if ($res.Count) { $failed++; Write-Host "PSScriptAnalyzer: $($res.Count) finding(s)" -ForegroundColor Red }
        else { Write-Host 'PSScriptAnalyzer: no findings' -ForegroundColor Green }
    }
}
exit $failed
