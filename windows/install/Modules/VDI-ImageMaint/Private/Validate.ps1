# -Mode Validate: checks packages.json without changing anything (also run before Packages/Update).
# Rules mirror Templates\packages.schema.json (the schema helps editors; this code runs in PS 5.1 without Test-Json).
# Findings: ERR = the manifest would be misread or fail; WARN = probably a mistake or a missing file.

$script:ValidationRules = @{
    Top = @{
        Profile = 'enum:University,Business,Graphics'; Variables = 'object'; Osot = 'object'; Build = 'object'
        Winget = 'object'; Ignore = 'regex[]'; Packages = 'array'
    }
    Package = @{
        Id = 'string'; Name = 'string'; Enabled = 'bool'; Order = 'int'; Type = 'enum:exe,msi,msp,msu,cab,odt,appx,ps1'
        File = 'string'; Archive = 'string'; Recurse = 'bool'; PreferPath = 'regex'; ExcludePath = 'regex'
        FileInfoMatch = 'regex'; Multiple = 'bool'; Version = 'string'; Arguments = 'string'; Detect = 'object'
        RequireInstalled = 'bool'; SuccessCodes = 'int[]'; RebootCodes = 'int[]'; RebootAfter = 'bool'
        StopProcesses = 'string[]'; StopServices = 'string[]'; PreScript = 'string'; PostScript = 'string'
        StopOnError = 'bool'; Config = 'string'
    }
    Detect = @{ Type = 'enum:Uninstall,Hotfix,File,Appx,Registry,Always'; Name = 'string'; Path = 'string'; Value = 'string' }
    Osot = @{
        Optimize = 'bool'; Template = 'string'; Level = 'string'; SettingsFile = 'string'; CommonOptions = 'string[]'
        Finalize = 'string'; FinalizeBuild = 'string'; Report = 'bool'
    }
    Build = @{
        TimeZone = 'string'; InputLocale = 'string'; SystemLocale = 'string'; UserLocale = 'string'; UILanguage = 'string'
        ComputerName = 'string'; SkipRearm = 'bool'; PersistAllDeviceInstalls = 'bool'; SysprepVmMode = 'bool'
        KeepBitLocker = 'bool'; AutoLogonCount = 'int'; PostGeneralizePackages = 'string[]'; RemoveUserAppx = 'string[]'
        AppxSettleSeconds = 'int'
    }
    Winget = @{ Install = 'string[]' }
}

function Add-Finding {
    param([System.Collections.Generic.List[object]]$List, [ValidateSet('ERR', 'WARN')][string]$Level, [string]$Path, [string]$Message)
    $List.Add([pscustomobject]@{ Level = $Level; Path = $Path; Message = $Message })
}

function Test-ValueType {
    # $Rule: string | bool | int | object | array | regex | enum:a,b | string[] | int[] | regex[]
    # Returns '' when the value fits, otherwise the localized problem.
    param($Value, [string]$Rule)
    if ($Rule.EndsWith('[]')) {
        if ($Value -isnot [System.Array]) { return (T 'val.notArray') }
        foreach ($v in $Value) { $r = Test-ValueType -Value $v -Rule $Rule.Substring(0, $Rule.Length - 2); if ($r) { return $r } }
        return ''
    }
    switch -Regex ($Rule) {
        '^string$' { if ($Value -isnot [string]) { return (T 'val.notString') } }
        '^bool$'   { if ($Value -isnot [bool]) { return (T 'val.notBool' $Value) } }   # "false" as text is True for PowerShell (S6)
        '^int$'    { if (-not ($Value -is [int] -or $Value -is [long])) { return (T 'val.notInt' $Value) } }
        '^object$' { if ($Value -isnot [pscustomobject]) { return (T 'val.notObject') } }
        '^array$'  { if ($Value -isnot [System.Array]) { return (T 'val.notArray') } }
        '^regex$'  {
            if ($Value -isnot [string]) { return (T 'val.notString') }
            try { [void][regex]::new($Value) }
            catch {
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                return (T 'val.badRegex' $Value $ex.Message)
            }
        }
        '^enum:(.+)$' {
            $allowed = $Matches[1] -split ','
            if ($Value -isnot [string] -or $allowed -notcontains $Value) { return (T 'val.badEnum' $Value ($allowed -join ', ')) }
        }
    }
    return ''
}

function Get-EditDistance {
    # Levenshtein distance - suggests the intended field name for a typo
    param([string]$A, [string]$B)
    $prev = 0..$B.Length
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = @($i) + @(0) * $B.Length
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = $(if ($A[$i - 1] -ceq $B[$j - 1]) { 0 } else { 1 })
            $best = [Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1)
            $cur[$j] = [Math]::Min($best, $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$B.Length]
}
function Test-ObjectFields {
    # Known fields with the right type; unknown fields (typos) are warnings; '_' / '$' keys are comments
    param($Obj, [hashtable]$Rules, [string]$Path, [System.Collections.Generic.List[object]]$List)
    foreach ($p in $Obj.PSObject.Properties) {
        if ($p.Name -like '_*' -or $p.Name -like '$*') { continue }
        if (-not $Rules.ContainsKey($p.Name)) {
            $near = @($Rules.Keys | Where-Object { (Get-EditDistance $_.ToLower() $p.Name.ToLower()) -le 2 } | Sort-Object)
            $hint = $(if ($near.Count) { ' ' + (T 'val.didYouMean' $near[0]) } else { '' })
            Add-Finding $List WARN "$Path.$($p.Name)" ((T 'val.unknownField') + $hint)
            continue
        }
        if ($null -eq $p.Value) { continue }
        $r = Test-ValueType -Value $p.Value -Rule $Rules[$p.Name]
        if ($r) { Add-Finding $List ERR "$Path.$($p.Name)" $r }
    }
}

function Test-FinalizeSet {
    param([string]$Text, [string]$Path, [bool]$Build, [System.Collections.Generic.List[object]]$List)
    if (-not $Text -or $Text -eq 'none') { return }
    $steps = @($Text -split '\s+' | Where-Object { $_ })
    foreach ($s in $steps) {
        if ($s -ne 'all' -and ($s -notmatch '^\d+$' -or [int]$s -gt 11)) { Add-Finding $List ERR $Path (T 'val.finalizeStep' $s) }
    }
    # Instant Clone: Compact (2) costs CPU on every clone; zeroing (7) only makes sense on the initial build before a thin export
    if ($steps -contains '2' -or $steps -contains 'all') { Add-Finding $List WARN $Path (T 'val.finalizeCompact') }
    if (-not $Build -and ($steps -contains '7' -or $steps -contains 'all')) { Add-Finding $List WARN $Path (T 'val.finalizeZero') }
}

function Test-Manifest {
    # Returns the findings; -Show prints them with a summary
    param([string]$Path = (Get-ManifestPath), [switch]$Show)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $Path)) {
        Add-Finding $list ERR 'packages.json' (T 'val.noFile' $Path)
    } else {
        $m = $null
        try { $m = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Add-Finding $list ERR 'packages.json' (T 'val.json' $_.Exception.Message) }
        if ($m) { Test-ManifestObject -Manifest $m -List $list }
    }
    if ($Show) { Show-ValidationResult -Findings $list -Path $Path }
    return $list.ToArray()
}

function Test-ManifestObject {
    param($Manifest, [System.Collections.Generic.List[object]]$List)
    $rules = $script:ValidationRules
    Test-ObjectFields -Obj $Manifest -Rules $rules.Top -Path '$' -List $List

    # --- Variables: strings only ---
    $vars = @{ File = 1; Dir = 1; Log = 1; InstallDir = 1 }
    $mv = Get-PV $Manifest 'Variables'
    if ($mv -is [pscustomobject]) {
        foreach ($p in $mv.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $vars[$p.Name] = 1
            if ($p.Value -isnot [string]) { Add-Finding $List WARN "Variables.$($p.Name)" (T 'val.notString') }
        }
    }

    # --- Osot ---
    $o = Get-PV $Manifest 'Osot'
    if ($o -is [pscustomobject]) {
        Test-ObjectFields -Obj $o -Rules $rules.Osot -Path 'Osot' -List $List
        Test-FinalizeSet -Text ([string](Get-PV $o 'Finalize' '')) -Path 'Osot.Finalize' -Build $false -List $List
        Test-FinalizeSet -Text ([string](Get-PV $o 'FinalizeBuild' '')) -Path 'Osot.FinalizeBuild' -Build $true -List $List
        $co = @(Get-PV $o 'CommonOptions' @()) -join ' '
        if ($co -match '-storeapp\s+remove-all' -and $co -notmatch '(?i)--exclude\b[^-]*\bMSTeams\b') {
            Add-Finding $List WARN 'Osot.CommonOptions' (T 'val.teamsRemoved')
        }
        $sf = [string](Get-PV $o 'SettingsFile' '')
        if ($sf) {
            $sfPath = $(if ([IO.Path]::IsPathRooted($sf)) { $sf } else { Join-Path $InstallDir $sf })
            if (-not (Test-Path $sfPath)) { Add-Finding $List WARN 'Osot.SettingsFile' (T 'val.missingFile' $sfPath) }
        }
    }

    # --- Build ---
    $b = Get-PV $Manifest 'Build'
    $ids = @{}
    $pkgs = @(Get-PV $Manifest 'Packages' @())
    foreach ($p in $pkgs) { $i = [string](Get-PV $p 'Id' ''); if ($i) { $ids[$i] = $p } }
    if ($b -is [pscustomobject]) {
        Test-ObjectFields -Obj $b -Rules $rules.Build -Path 'Build' -List $List
        foreach ($id in @(Get-PV $b 'PostGeneralizePackages' @())) {
            if ($id -is [string] -and -not $ids.ContainsKey($id)) { Add-Finding $List ERR 'Build.PostGeneralizePackages' (T 'val.unknownId' $id) }
        }
    }

    # --- Winget ---
    $w = Get-PV $Manifest 'Winget'
    if ($w -is [pscustomobject]) { Test-ObjectFields -Obj $w -Rules $rules.Winget -Path 'Winget' -List $List }

    # --- Packages ---
    $seen = @{}
    for ($n = 0; $n -lt $pkgs.Count; $n++) {
        $p = $pkgs[$n]
        $id = [string](Get-PV $p 'Id' '')
        $path = "Packages[$n]" + $(if ($id) { " ($id)" } else { '' })
        if ($p -isnot [pscustomobject]) { Add-Finding $List ERR $path (T 'val.notObject'); continue }
        Test-ObjectFields -Obj $p -Rules $rules.Package -Path $path -List $List
        if (-not $id) { Add-Finding $List ERR $path (T 'val.required' 'Id') }
        elseif ($seen.ContainsKey($id)) { Add-Finding $List ERR $path (T 'val.duplicateId' $id) }
        else { $seen[$id] = 1 }
        if (-not (Get-PV $p 'File' '')) { Add-Finding $List ERR $path (T 'val.required' 'File') }

        $det = Get-PV $p 'Detect'
        if ($det -is [pscustomobject]) {
            Test-ObjectFields -Obj $det -Rules $rules.Detect -Path "$path.Detect" -List $List
            $need = @{ Uninstall = @('Name'); File = @('Path'); Appx = @('Name'); Registry = @('Path', 'Name', 'Value') }[[string](Get-PV $det 'Type' 'Always')]
            foreach ($f in @($need)) { if ($f -and -not (Get-PV $det $f '')) { Add-Finding $List ERR "$path.Detect" (T 'val.detectNeeds' (Get-PV $det 'Type' '') $f) } }
            if ([string](Get-PV $det 'Type' '') -eq 'Uninstall' -and (Get-PV $det 'Name' '')) {
                $r = Test-ValueType -Value (Get-PV $det 'Name' '') -Rule 'regex'
                if ($r) { Add-Finding $List ERR "$path.Detect.Name" $r }
            }
        }

        # {Variable} in Arguments must be known (GUIDs with '-' do not match \w+)
        foreach ($v in [regex]::Matches([string](Get-PV $p 'Arguments' ''), '\{(\w+)\}')) {
            if (-not $vars.ContainsKey($v.Groups[1].Value)) { Add-Finding $List WARN "$path.Arguments" (T 'val.unknownVar' $v.Groups[1].Value) }
        }

        # Files: only enabled packages need them now
        $enabled = (Get-PV $p 'Enabled' $true) -eq $true
        if ($enabled -and (Get-PV $p 'File' '') -and @(Resolve-PackageFiles $p).Count -eq 0) {
            Add-Finding $List WARN $path (T 'val.noPackageFile' (Get-PV $p 'File' ''))
        }
        if ([string](Get-PV $p 'Type' '') -eq 'odt' -and $enabled) {
            $setup = @(Resolve-PackageFiles $p) | Select-Object -First 1
            if ($setup -and -not (Resolve-OdtConfig $p $setup)) { Add-Finding $List ERR $path (T 'plan.reason.noOdtXml') }
        }
        if ($id -eq 'FSLogixConfig' -and $enabled -and -not [string](Get-PV $mv 'FSLogixShare' '')) {
            Add-Finding $List ERR $path (T 'val.noShare')
        }
    }
}

function Show-ValidationResult {
    param([object[]]$Findings, [string]$Path)
    Write-Log (T 'val.step' $Path) STEP
    foreach ($f in @($Findings | Sort-Object @{ Expression = { $_.Level -ne 'ERR' } }, Path)) {
        Write-Log ("{0}: {1}" -f $f.Path, $f.Message) $(if ($f.Level -eq 'ERR') { 'ERR' } else { 'WARN' })
    }
    $e = @($Findings | Where-Object Level -eq 'ERR').Count
    $w = @($Findings | Where-Object Level -eq 'WARN').Count
    if ($e) { Write-Log (T 'val.summaryErr' $e $w) ERR }
    elseif ($w) { Write-Log (T 'val.summaryWarn' $w) WARN }
    else { Write-Log (T 'val.ok') OK }
}

function Invoke-Validate {
    $f = Test-Manifest -Show
    if (@($f | Where-Object Level -eq 'ERR').Count) { throw (T 'val.failed') }
}

function Assert-ManifestValid {
    # Before installing: stop on errors (warnings only shown)
    $f = Test-Manifest
    $e = @($f | Where-Object Level -eq 'ERR')
    if ($e.Count) {
        Show-ValidationResult -Findings $f -Path (Get-ManifestPath)
        throw (T 'val.blocked' $e.Count)
    }
}
