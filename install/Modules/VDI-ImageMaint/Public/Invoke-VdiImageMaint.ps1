function Invoke-VdiImageMaint {
    <#
    .SYNOPSIS
        Entry point of the module, called by VDI-ImageMaint.ps1. Returns the process exit code.
    .PARAMETER Parameters
        All parameters of the entry script (bound and default values) - copied into module scope,
        so the functions read $InstallDir, $WingetAll, ... directly.
    .PARAMETER BoundParameters
        Only the parameters given on the command line - forwarded to the resume task and the SYSTEM task.
    .PARAMETER EntryScript
        Full path of VDI-ImageMaint.ps1 (resume task, SYSTEM task, FirstLogonCommands).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Parameters,
        [hashtable]$BoundParameters = @{},
        [Parameter(Mandatory)][string]$EntryScript
    )

    foreach ($k in $Parameters.Keys) { Set-Variable -Name $k -Value $Parameters[$k] -Scope Script }
    $script:EntryScript = $EntryScript
    $script:BoundParams = @{}
    foreach ($k in $BoundParameters.Keys) { $script:BoundParams[$k] = $BoundParameters[$k] }
    Initialize-Strings -Language $Language

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $script:isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    if (-not $isSystem -and (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false   # we are the resumed run
    }
    $exitCode = 0
    $adminOnly = @('Update', 'WingetList', 'Packages', 'PackageList', 'Optimize', 'Finalize', 'Init', 'Discover',
        'Generalize', 'PostGeneralize', 'Configure', 'Download')

    if ($AsSystem -and -not $isSystem) {
        if ($Mode -in $adminOnly) { throw (T 'main.adminOnly' $Mode) }
        try {
            # OSOT must run from the administrator account (HKCU -> Default User sync), not as SYSTEM
            if ($Mode -eq 'Seal') { $exitCode = Invoke-SealAsSystemFlow }
            else {
                $exitCode = Invoke-AsSystem
                if ($Mode -eq 'Inventory') { Export-WingetToLastInventory }
            }
        } catch {
            Write-Log $_.Exception.Message ERR
            $exitCode = 1
        }
    } else {
        $log = Join-Path $LogDir ('{0}_{1}.log' -f $Mode, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Start-Transcript -Path $log -Force | Out-Null
        try {
            Write-Log (T 'main.header' $script:ToolVersion $Mode $env:COMPUTERNAME ([Security.Principal.WindowsIdentity]::GetCurrent().Name))
            # $null = : stray pipeline output of a mode must not end up in the exit code
            $null = switch ($Mode) {
                'Status'         { Show-Status }
                'WingetList'     { Show-WingetList }
                'PackageList'    { Invoke-PackagePlatform -DryRun; Install-WingetApps -DryRun; Write-Log 'OSOT' STEP; Show-OsotConfig }
                'Configure'      { Invoke-Configure }
                'Init'           { Invoke-Init }
                'Discover'       { Invoke-Discover }
                'Optimize'       { Show-OsotConfig; Save-SealBaseline; Invoke-OsotSealPre }
                'Finalize'       { Invoke-OsotFinalize }
                'Packages'       { Invoke-PackagePlatform; if ($script:PackageRunResult -ne 'reboot' -and -not $SkipWinget) { Install-WingetApps } }
                'Inventory'      { Invoke-Inventory }
                'Unlock' {
                    $issues = Invoke-Unlock
                    Show-Status
                    if ($issues -gt 0) { $exitCode = 1 }   # exit code for Invoke-AsSystem (B7)
                }
                'Update'         { Invoke-Update }
                'Seal'           { Invoke-Seal }
                'Generalize'     { Invoke-Generalize }
                'PostGeneralize' { Invoke-PostGeneralize }
            }
        } catch {
            if ($_.Exception.Message -eq $script:RestartSignal) { $exitCode = 0 }   # reboot scheduled - not an error
            else {
                Write-Log $_.Exception.Message ERR
                $exitCode = 1
            }
        } finally {
            # S3: the transcript may already be stopped (reboot with resume, Generalize)
            try { Stop-Transcript | Out-Null } catch { }
        }
    }

    $shutdownMode = ($Mode -in @('Seal', 'PostGeneralize')) -or ($Mode -eq 'Update' -and $script:SealDone)
    if ($Shutdown -and $shutdownMode -and $exitCode -eq 0 -and -not $isSystem) {
        Write-Log (T 'main.shutdown') WARN
        Start-Sleep -Seconds 15
        Stop-Computer -Force
    }
    return $exitCode
}
