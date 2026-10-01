# Logging, registry and JSON helpers shared by all areas.

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO'
    )
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }[$Level]
    if ($Level -eq 'STEP') { Write-Host '' }
    Write-Host ('[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Get-RegValue {
    # No exceptions for a missing key/value (PS 5.1 writes caught exceptions to the transcript)
    param([string]$Path, [string]$Name)
    if (-not $Path) { return $null }   # Get-Item -LiteralPath '' throws a binding error that SilentlyContinue does not suppress
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    return $key.GetValue($Name, $null)
}

function Get-PV {
    # Safe property read from a JSON object (StrictMode)
    param($Obj, [string]$Name, $Default = $null)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Set-PV {
    # Sets or adds a property of a JSON object
    param($Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($Object.PSObject.Properties[$Name]) { return [string]$Object.$Name } else { return '' }
}

function Test-PendingReboot {
    $r = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r += 'WindowsUpdate' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $r += 'PendingFileRename' }
    return $r
}

function Resolve-ServiceDefs {
    # Expands patterns (e.g. GoogleUpdaterService*) to the services that actually exist
    $all = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    foreach ($d in $ServiceDefs) {
        if ($d.Name -match '[\*\?]') {
            foreach ($n in @($all | Where-Object { $_ -like $d.Name })) { @{ Name = $n; Default = $d.Default } }
        } elseif ($all -contains $d.Name) {
            $d
        }
    }
}

function Get-InstalledApps {
    $hives = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Arch = 'x64' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = 'x86' }
    )
    foreach ($h in $hives) {
        Get-ItemProperty -Path $h.Path -ErrorAction SilentlyContinue |
            # Get-Prop returns a string: SystemComponent=0 gives '0', which is truthy - compare with '1'
            Where-Object { (Get-Prop $_ 'DisplayName') -and (Get-Prop $_ 'SystemComponent') -ne '1' -and -not (Get-Prop $_ 'ParentKeyName') } |
            ForEach-Object {
                [pscustomobject]@{
                    Name            = Get-Prop $_ 'DisplayName'
                    Version         = Get-Prop $_ 'DisplayVersion'
                    Publisher       = Get-Prop $_ 'Publisher'
                    InstallDate     = Get-Prop $_ 'InstallDate'
                    InstallLocation = Get-Prop $_ 'InstallLocation'
                    Arch            = $h.Arch
                }
            }
    }
}

function Show-AppDiff {
    param($Before, $After)
    $b = @{}; foreach ($x in $Before) { $b[$x.Name] = $x.Version }
    $a = @{}; foreach ($x in $After)  { $a[$x.Name] = $x.Version }
    $changes = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { $changes += [pscustomobject]@{ App = $k; Before = (T 'appdiff.new'); After = $a[$k] } }
        elseif ($b[$k] -ne $a[$k])   { $changes += [pscustomobject]@{ App = $k; Before = $b[$k]; After = $a[$k] } }
    }
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k)) { $changes += [pscustomobject]@{ App = $k; Before = $b[$k]; After = (T 'appdiff.removed') } }
    }
    Write-Log (T 'appdiff.step') STEP
    if ($changes.Count -eq 0) { Write-Log (T 'appdiff.none'); return }
    $changes | Sort-Object App | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

function Get-MatchingTasks {
    $seen = @{}
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $full = $t.TaskPath + $t.TaskName
        foreach ($p in $TaskPatterns) {
            if ($full -like $p -and -not $seen.ContainsKey($full)) { $seen[$full] = $true; $t; break }
        }
    }
}

function ConvertTo-ArgumentText {
    # Parameters in PowerShell syntax (for -Command / -EncodedCommand, NOT for -File - there quotes stay in the value)
    param($Params, [string[]]$Exclude = @())
    $parts = @()
    foreach ($k in @($Params.Keys)) {
        if ($Exclude -contains $k) { continue }
        $v = $Params[$k]
        if ($v -is [securestring]) { continue }   # passwords never go to a command line
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $parts += "-$k" }; continue }
        $vals = @(@($v) | ForEach-Object { "'" + ([string]$_ -replace "'", "''") + "'" })
        $parts += ("-$k " + ($vals -join ','))
    }
    return ($parts -join ' ')
}

function ConvertTo-EncodedCommand {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function Format-Json {
    # PS 5.1 ConvertTo-Json: uneven indentation and < escapes - readable format for manual editing
    param([string]$Json)
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    foreach ($line in ($Json -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^[\}\]]') { $indent-- }
        $t = $t -replace '^("(?:[^"\\]|\\.)*"):\s+', '$1: '
        [void]$sb.Append(('  ' * [Math]::Max($indent, 0)) + $t + "`r`n")
        if ($t -match '[\{\[]$') { $indent++ }
    }
    $out = $sb.ToString()
    # < > & ' -> < > & ' (the hex code is built here so the source never contains the escape)
    foreach ($p in @(@('3c', '<'), @('3e', '>'), @('26', '&'), @('27', "'"))) {
        $out = $out -replace ('(?<!\\)\\u00' + $p[0]), $p[1]
    }
    return $out
}

function Save-TextWithBackup {
    param([string]$Path, [string]$Text)
    if (Test-Path $Path) {
        $bak = "$Path.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -Path $Path -Destination $bak -Force
        Write-Log (T 'file.backup' $bak)
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log (T 'file.saved' $Path) OK
}

function Stop-ForRestart {
    # Ends the current run after a reboot was scheduled (the entry point exits with code 0)
    try { Stop-Transcript | Out-Null } catch { }
    throw $script:RestartSignal
}
