# Package platform: manifest (packages.json), file resolution, version detection, install plan, installation.
# Plan actions are language-neutral codes: install | update | skip | current | missing (shown via T 'plan.action.<code>').

function ConvertTo-Version {
    # Tolerates parts > Int32 (e.g. Horizon 8.16.0.16560454767) - such parts are dropped;
    # the result always has 4 parts, so 8.16.0 == 8.16.0.0
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    $nums = @()
    foreach ($part in $m.Value.Split('.')) {
        $n = 0L
        if ([long]::TryParse($part, [ref]$n) -and $n -le [int]::MaxValue) { $nums += [int]$n } else { break }
    }
    if ($nums.Count -lt 2) { return $null }
    while ($nums.Count -lt 4) { $nums += 0 }
    return (New-Object System.Version -ArgumentList $nums[0], $nums[1], $nums[2], $nums[3])
}

function Get-MsiProperty {
    param([string]$Path, [string]$Property)
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $v  = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
        $r  = $v.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $v, $null)
        if (-not $r) { return $null }
        $val = $r.GetType().InvokeMember('StringData', 'GetProperty', $null, $r, 1)
        [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
        return $val
    } catch { return $null }
}

function Get-MsiVersion { param([string]$Path) return (Get-MsiProperty $Path 'ProductVersion') }

function Get-FileVersionText {
    param($File)
    if ($File.Extension -eq '.msi') { return (Get-MsiVersion $File.FullName) }
    if ($File.Extension -match '^\.(msix|msixbundle|appx|appxbundle|msu|cab|zip|ps1|xml)$') {
        $v = ConvertTo-Version ($File.BaseName -replace '^[^_]*_', '')
        if ($v) { return $v.ToString() } else { return '' }
    }
    # EXE: the first value a version can be read from (ProductVersion is sometimes e.g. "2506")
    $vi = $File.VersionInfo
    foreach ($cand in @($vi.ProductVersion, $vi.FileVersion, $File.BaseName)) {
        if ($cand -and (ConvertTo-Version $cand)) { return [string]$cand }
    }
    return [string]$vi.ProductVersion
}

function Expand-PkgString {
    param([string]$Text, [hashtable]$Vars)
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace('{' + $k + '}', [string]$Vars[$k]) }
    return $Text
}

function Get-ManifestPath {
    if ($Manifest) { if ([IO.Path]::IsPathRooted($Manifest)) { return $Manifest } else { return (Join-Path $InstallDir $Manifest) } }
    return (Join-Path $InstallDir 'packages.json')
}

function Get-PackageManifest {
    $path = Get-ManifestPath
    if (-not (Test-Path $path)) {
        if (-not (Test-Path $InstallDir)) { Write-Log (T 'pkg.noInstallDir' $InstallDir) ERR; return $null }
        Write-Log (T 'pkg.createDefault' $path) WARN
        Copy-Item -Path $DefaultManifestFile -Destination $path
    }
    try { return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Log (T 'pkg.jsonError' $path $_.Exception.Message) ERR; return $null }
}

function Find-PackageFiles {
    param([string]$Root, [string]$Pattern, [bool]$Recurse = $true)
    if (-not (Test-Path $Root)) { return }
    $leaf = Split-Path $Pattern -Leaf
    $sub  = Split-Path $Pattern -Parent
    $base = if ($sub) { Join-Path $Root $sub } else { $Root }
    if (-not (Test-Path $base)) { return }
    if ($Recurse) { Get-ChildItem -Path $base -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue }
    else          { Get-ChildItem -Path $base -File -Filter $leaf -ErrorAction SilentlyContinue }
}

function Resolve-PackageFiles {
    param($Pkg)
    $pattern = [string](Get-PV $Pkg 'File' '')
    if (-not $pattern) { return @() }
    $recurse = [bool](Get-PV $Pkg 'Recurse' $true)
    $roots = @($InstallDir)
    $archive = [string](Get-PV $Pkg 'Archive' '')
    if ($archive) {
        foreach ($z in @(Find-PackageFiles -Root $InstallDir -Pattern $archive)) {
            $dst = Join-Path $env:TEMP ('VDI-ImageMaint_' + $z.BaseName)
            if (-not (Test-Path $dst)) { Write-Log (T 'pkg.unzip' $z.Name); Expand-Archive -Path $z.FullName -DestinationPath $dst -Force }
            $roots += $dst
        }
    }
    $files = @(foreach ($r in $roots) { Find-PackageFiles -Root $r -Pattern $pattern -Recurse ($recurse -or $r -ne $InstallDir) })
    $prefer = [string](Get-PV $Pkg 'PreferPath' '')
    if ($prefer) { $pf = @($files | Where-Object { $_.FullName -match $prefer }); if ($pf.Count) { $files = $pf } }
    $excl = [string](Get-PV $Pkg 'ExcludePath' '')
    if ($excl) { $files = @($files | Where-Object { $_.FullName -notmatch $excl }) }
    $info = [string](Get-PV $Pkg 'FileInfoMatch' '')
    if ($info) { $files = @($files | Where-Object { "$($_.VersionInfo.ProductName) $($_.VersionInfo.FileDescription)" -match $info }) }
    return @($files | Sort-Object FullName -Unique)
}

function Get-KbFromName {
    param([string]$Name)
    if ($Name -match '(?i)(kb\d{6,8})') { return $Matches[1].ToUpper() }
    return $null
}

function Test-KbInstalled {
    param([string]$Kb)
    if ($null -eq $script:HotfixCache) {
        Write-Log (T 'pkg.readHotfix')
        $list = @(Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.HotFixID })
        foreach ($wp in @(Get-WindowsPackage -Online -ErrorAction SilentlyContinue)) {
            if ($wp.PackageName -match '(?i)(KB\d{6,8})' -and $wp.PackageState -match 'Installed|InstallPending') { $list += $Matches[1].ToUpper() }
        }
        $script:HotfixCache = $list
    }
    return ($script:HotfixCache -contains $Kb)
}

function Get-ProvisionedVersion {
    param([string]$Name)
    if ($null -eq $script:ProvCache) { $script:ProvCache = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) }
    $p = $script:ProvCache | Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
    if ($p) { return [string]$p.Version } else { return $null }
}

function Set-VersionAction {
    param($Plan, [string]$Current, [string]$New, [bool]$RequireInstalled)
    $Plan.Installed = $(if ($Current) { $Current } else { T 'plan.none' })
    $Plan.Package   = $New
    if (-not $Current) {
        if ($RequireInstalled) { $Plan.Action = 'skip'; $Plan.Reason = T 'plan.reason.requireInstalled' }
        else { $Plan.Action = 'install'; $Plan.Reason = T 'plan.reason.new' }
        return
    }
    $cv = ConvertTo-Version $Current; $nv = ConvertTo-Version $New
    if (-not $nv)                 { $Plan.Action = 'skip'; $Plan.Reason = T 'plan.reason.noVersion' }
    elseif ($cv -and $nv -le $cv) { $Plan.Action = 'current' }
    else                          { $Plan.Action = 'update' }
}

function Test-OdtInstallXml {
    # ODT install configuration: has <Add>, has no <Remove> (rejects e.g. Uninstall.xml)
    param([string]$Path)
    try {
        [xml]$x = Get-Content -Path $Path -Raw -ErrorAction Stop
        return ([bool]$x.SelectSingleNode('/Configuration/Add') -and -not $x.SelectSingleNode('/Configuration/Remove'))
    } catch { return $false }
}

function Resolve-OdtConfig {
    # 1) absolute path from the Config field  2) file named in Config next to setup.exe / in the root / in subfolders
    # 3) automatic: the only ODT install XML next to setup.exe (with several - the one with "x64" in the name)
    param($Pkg, $SetupFile)
    $cfg = [string](Get-PV $Pkg 'Config' '')
    if ($cfg) {
        if ([IO.Path]::IsPathRooted($cfg)) { if (Test-Path $cfg) { return $cfg } else { return $null } }
        foreach ($d in @($SetupFile.DirectoryName, $InstallDir)) {
            $c = Join-Path $d $cfg
            if (Test-Path $c) { return $c }
        }
        $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter (Split-Path $cfg -Leaf) -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Office\\Data\\' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $xmls = @(Get-ChildItem -Path $SetupFile.DirectoryName -File -Filter '*.xml' -ErrorAction SilentlyContinue |
        Where-Object { Test-OdtInstallXml $_.FullName })
    if ($xmls.Count -gt 1) {
        $x64 = @($xmls | Where-Object { $_.Name -match '(?i)x64|64' })
        if ($x64.Count) { $xmls = $x64 }
    }
    if ($xmls.Count -ge 1) { return ($xmls | Sort-Object Name | Select-Object -First 1).FullName }
    return $null
}

function Get-PackagePlan {
    param($Pkg, $Installed)
    $id = [string](Get-PV $Pkg 'Id' (T 'plan.noId'))
    $plan = [pscustomobject]@{
        Order = [int](Get-PV $Pkg 'Order' 100); Id = $id; Name = [string](Get-PV $Pkg 'Name' $id)
        Type = ([string](Get-PV $Pkg 'Type' 'exe')).ToLower(); Installed = ''; Package = ''
        Action = ''; Reason = ''; Files = @(); Pkg = $Pkg
    }
    $forced  = ($script:ForceInstallIds -contains $id)   # PostGeneralize: fresh install of the agents
    $enabled = [bool](Get-PV $Pkg 'Enabled' $true) -or $forced
    $files = @(Resolve-PackageFiles $Pkg)
    if ($files.Count -eq 0) {
        $plan.Action = 'missing'; $plan.Reason = [string](Get-PV $Pkg 'File' '')
        if (-not $enabled) { $plan.Reason += ' ' + (T 'plan.reason.disabledTag') }
        return $plan
    }
    if ($plan.Type -eq 'odt') {
        $withCfg = @($files | Where-Object { Resolve-OdtConfig $Pkg $_ })
        if ($withCfg.Count -eq 0) {
            $plan.Action = 'missing'
            $plan.Reason = T 'plan.reason.noOdtXml'
            return $plan
        }
        $near = @($withCfg | Where-Object { (Split-Path (Resolve-OdtConfig $Pkg $_) -Parent) -eq $_.DirectoryName })
        $files = @($(if ($near.Count) { $near } else { $withCfg }))
    }
    if (-not [bool](Get-PV $Pkg 'Multiple' $false) -and $files.Count -gt 1) {
        $files = @($files | Sort-Object @{ Expression = { ConvertTo-Version (Get-FileVersionText $_) }; Descending = $true },
                                        @{ Expression = { $_.LastWriteTime }; Descending = $true } | Select-Object -First 1)
    }
    $pkgVersion = [string](Get-PV $Pkg 'Version' '')
    if (-not $pkgVersion) { $pkgVersion = [string](Get-FileVersionText $files[0]) }
    $req    = [bool](Get-PV $Pkg 'RequireInstalled' $false) -and -not $forced
    $detect = Get-PV $Pkg 'Detect'
    $dType  = [string](Get-PV $detect 'Type' 'Always')

    switch ($dType) {
        'Uninstall' {
            $rx  = [string](Get-PV $detect 'Name' '^$')
            $app = @($Installed | Where-Object { $_.Name -match $rx }) |
                Sort-Object @{ Expression = { ConvertTo-Version $_.Version }; Descending = $true } | Select-Object -First 1
            Set-VersionAction -Plan $plan -Current $(if ($app) { $app.Version } else { '' }) -New $pkgVersion -RequireInstalled $req
        }
        'Hotfix' {
            $todo = @(); $done = @()
            foreach ($f in $files) {
                $kb = Get-KbFromName $f.Name
                if ($kb -and (Test-KbInstalled $kb)) { $done += $kb } else { $todo += $f }
            }
            $files = $todo
            $plan.Installed = $(if ($done.Count) { $done -join ', ' } else { '-' })
            $plan.Package   = (@($todo | ForEach-Object { $k = Get-KbFromName $_.Name; if ($k) { $k } else { $_.Name } }) -join ', ')
            $plan.Action    = $(if ($todo.Count) { 'install' } else { 'current' })
        }
        'File' {
            $path = [string](Get-PV $detect 'Path' '')
            $cur  = if ($path -and (Test-Path $path)) { (Get-Item $path).VersionInfo.FileVersion } else { '' }
            Set-VersionAction -Plan $plan -Current $cur -New $pkgVersion -RequireInstalled $req
        }
        'Appx' {
            $cur = Get-ProvisionedVersion ([string](Get-PV $detect 'Name' ''))
            Set-VersionAction -Plan $plan -Current $cur -New $pkgVersion -RequireInstalled $req
        }
        'Registry' {
            $cur  = [string](Get-RegValue ([string](Get-PV $detect 'Path' '')) ([string](Get-PV $detect 'Name' '')))
            $want = [string](Get-PV $detect 'Value' '')
            $plan.Installed = $(if ($cur) { $cur } else { T 'plan.none' }); $plan.Package = $want
            $plan.Action = $(if ($cur -eq $want) { 'current' } else { 'install' })
        }
        default {
            $plan.Package = $pkgVersion; $plan.Action = 'install'; $plan.Reason = T 'plan.reason.always'
        }
    }
    if ($plan.Type -eq 'odt') {
        $plan.Installed = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'VersionToReport')
        if (-not $plan.Installed) { $plan.Installed = T 'plan.none' }
        $plan.Package = T 'plan.byChannel'
        $plan.Reason  = "ODT $pkgVersion, config: $(Resolve-OdtConfig $Pkg $files[0])"
    }
    $plan.Files = $files
    # Horizon Agent: the installer must support the running Windows release (KB 78714)
    if ([string](Get-PV $detect 'Name' '') -match 'Horizon Agent' -and $plan.Action -in 'install', 'update') {
        $hz = Get-HorizonAgentSupportText -AgentVersion (Get-HorizonAgentVersion "$($files[0].Name) $pkgVersion") -Release (Get-WindowsRelease)
        if ($hz) { $plan.Reason = (@($plan.Reason, $hz) | Where-Object { $_ }) -join '; '; Write-Log "[$id] $hz" WARN }
    }
    if (-not $enabled -and $plan.Action -in 'install', 'update') {
        $plan.Reason = T 'plan.reason.disabled' (T "plan.action.$($plan.Action)"); $plan.Action = 'skip'
    } elseif ($PackageIds -and $PackageIds -notcontains $id -and $plan.Action -in 'install', 'update') {
        $plan.Reason = T 'plan.reason.notSelected' (T "plan.action.$($plan.Action)"); $plan.Action = 'skip'
    }
    return $plan
}

function Install-PlannedPackage {
    param($Plan, [hashtable]$Vars)
    $pkg = $Plan.Pkg
    $defaultOk = if ($Plan.Type -in 'msu', 'cab') { @(0, -2146498530, 2359302) } else { @(0) }   # 0x800F081E = not applicable
    $okCodes     = @(Get-PV $pkg 'SuccessCodes' $defaultOk)
    $rebootCodes = @(Get-PV $pkg 'RebootCodes' @(3010, 1641))

    foreach ($pn in @(Get-PV $pkg 'StopProcesses' @())) { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    foreach ($sn in @(Get-PV $pkg 'StopServices' @()))  { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
    $pre = [string](Get-PV $pkg 'PreScript' '')
    if ($pre) { Write-Log "[$($Plan.Id)] PreScript"; & ([scriptblock]::Create($pre)) | Out-Null }

    $failed = $false; $reboot = $false
    foreach ($f in $Plan.Files) {
        $log = Join-Path $LogDir ('PKG_{0}_{1}_{2}.log' -f $Plan.Id, $f.BaseName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $v = $Vars.Clone(); $v['File'] = $f.FullName; $v['Dir'] = $f.DirectoryName; $v['Log'] = $log
        $argText = Expand-PkgString ([string](Get-PV $pkg 'Arguments' '')) $v
        $rc = $null; $exe = $null; $al = ''; $shown = $null

        if ($Plan.Type -eq 'odt') {
            $cfg = Resolve-OdtConfig $pkg $f
            if (-not $cfg) { Write-Log (T 'pkg.noOdtXml' $Plan.Id $f.FullName) ERR; $failed = $true; break }
            Write-Log "[$($Plan.Id)] setup.exe: $($f.FullName) | config: $cfg"
            $ok = Update-OfficeOdt -Odt $f.FullName -Xml $cfg
            $script:OfficeHandled = $true
            $rc = $(if ($ok) { 0 } else { 1 })
        } elseif ($Plan.Type -eq 'appx') {
            try {
                $deps = @()
                $depDir = Join-Path $f.DirectoryName 'Dependencies'
                if (Test-Path $depDir) { $deps = @(Get-ChildItem $depDir -Recurse -File -Include '*.appx', '*.msix' | Where-Object { $_.FullName -notmatch '(?i)arm|x86' } | ForEach-Object { $_.FullName }) }
                Write-Log "[$($Plan.Id)] Add-AppxProvisionedPackage $($f.Name)"
                if ($deps.Count) { Add-AppxProvisionedPackage -Online -PackagePath $f.FullName -DependencyPackagePath $deps -SkipLicense -ErrorAction Stop | Out-Null }
                else             { Add-AppxProvisionedPackage -Online -PackagePath $f.FullName -SkipLicense -ErrorAction Stop | Out-Null }
                $rc = 0; $script:ProvCache = $null
            } catch { Write-Log "[$($Plan.Id)] $($_.Exception.Message)" ERR; $rc = 1 }
        } else {
            switch ($Plan.Type) {
                'exe' { $exe = $f.FullName; $al = $argText }
                'msi' { $exe = 'msiexec.exe'; $al = ("/i `"{0}`" /qn /norestart /l*v `"{1}`" {2}" -f $f.FullName, $log, $argText).Trim() }
                'msp' { $exe = 'msiexec.exe'; $al = ("/p `"{0}`" /qn /norestart /l*v `"{1}`" {2}" -f $f.FullName, $log, $argText).Trim() }
                'msu' { $exe = Join-Path $env:SystemRoot 'System32\dism.exe'; $al = "/Online /Add-Package /PackagePath:`"$($f.FullName)`" /Quiet /NoRestart /LogPath:`"$log`"" }
                'cab' { $exe = Join-Path $env:SystemRoot 'System32\dism.exe'; $al = "/Online /Add-Package /PackagePath:`"$($f.FullName)`" /Quiet /NoRestart /LogPath:`"$log`"" }
                'ps1' {
                    # -EncodedCommand instead of -File: Arguments use PowerShell syntax (quotes, arrays 'a','b');
                    # existing double-quoted entries behave the same
                    $exe = 'powershell.exe'
                    $cmdText = ("& '{0}' {1}; exit `$LASTEXITCODE" -f ($f.FullName -replace "'", "''"), $argText)
                    $al = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmdText)
                    $shown = "-Command $cmdText"
                }
                default { Write-Log (T 'pkg.unknownType' $Plan.Id $Plan.Type) ERR }
            }
            if (-not $exe) { $failed = $true; break }
            Write-Log "[$($Plan.Id)] $([IO.Path]::GetFileName($exe)) $(if ($shown) { $shown } else { $al })"
            $sp = @{ FilePath = $exe; Wait = $true; PassThru = $true; WorkingDirectory = $f.DirectoryName }
            if ($al) { $sp['ArgumentList'] = $al }
            try { $rc = (Start-Process @sp).ExitCode } catch { Write-Log "[$($Plan.Id)] $($_.Exception.Message)" ERR; $rc = -1 }
        }

        if ($rebootCodes -contains $rc) { $reboot = $true; Write-Log (T 'pkg.okReboot' $Plan.Id $f.Name $rc) OK }
        elseif ($okCodes -contains $rc) { Write-Log (T 'pkg.ok' $Plan.Id $f.Name $rc) OK }
        else {
            Write-Log (T 'pkg.error' $Plan.Id $f.Name $rc ([int]$rc) $log) ERR
            $failed = $true
            if ([bool](Get-PV $pkg 'StopOnError' $true)) { break }
        }
    }

    $post = [string](Get-PV $pkg 'PostScript' '')
    if ($post -and -not $failed) { Write-Log "[$($Plan.Id)] PostScript"; & ([scriptblock]::Create($post)) | Out-Null }
    return [pscustomobject]@{ Failed = $failed; Reboot = $reboot }
}

function Invoke-PackagePlatform {
    param([switch]$DryRun)
    $script:PackageRunResult = 'done'
    Write-Log $(if ($DryRun) { T 'pkg.stepPlan' } else { T 'pkg.stepInstall' }) STEP
    $m = Get-PackageManifest
    if (-not $m) { $script:PackageRunResult = 'error'; return }
    Write-Log (T 'pkg.manifest' (Get-ManifestPath))
    # a misread manifest must not install anything; the plan shows all findings
    if ($DryRun) { [void](Test-Manifest -Show) } else { Assert-ManifestValid }

    $vars = @{ InstallDir = $InstallDir }
    $mv = Get-PV $m 'Variables'
    if ($mv) { foreach ($pp in $mv.PSObject.Properties) { $vars[$pp.Name] = [string]$pp.Value } }

    $installed = @(Get-InstalledApps)
    $plans = @(@(foreach ($pkg in @(Get-PV $m 'Packages' @())) { Get-PackagePlan -Pkg $pkg -Installed $installed }) | Sort-Object Order, Id)
    $plans | Select-Object Order, Id, Type, Installed, Package, @{ n = 'Action'; e = { T "plan.action.$($_.Action)" } }, Reason |
        Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    Show-UnassignedFiles -ManifestObj $m
    if ($DryRun) { return }

    $todo = @($plans | Where-Object { $_.Action -in 'install', 'update' })
    if ($todo.Count -eq 0) { Write-Log (T 'pkg.nothing') OK; return }
    $errors = 0
    foreach ($pl in $todo) {
        Write-Log ("[{0}] {1}: {2} -> {3}" -f $pl.Id, $pl.Name, $pl.Installed, $pl.Package) STEP
        $r = Install-PlannedPackage -Plan $pl -Vars $vars
        $script:HotfixCache = $null
        if ($r.Failed) { $errors++ }
        if ($r.Reboot -and [bool](Get-PV $pl.Pkg 'RebootAfter' $false)) {
            Write-Log (T 'pkg.needsReboot' $pl.Id) WARN
            $script:PackageRunResult = 'reboot'
            Request-RebootAndResume
            return
        }
    }
    Write-Log (T 'pkg.summary' ($todo.Count - $errors) $errors) $(if ($errors) { 'WARN' } else { 'OK' })
}

function Get-RelativePath {
    param([string]$FullName)
    $root = $InstallDir.TrimEnd('\')
    if ($FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $FullName.Substring($root.Length + 1) }
    return $FullName
}

function Get-UnassignedFiles {
    param($ManifestObj)
    $assigned = @{}
    foreach ($pkg in @(Get-PV $ManifestObj 'Packages' @())) {
        foreach ($f in @(Resolve-PackageFiles $pkg)) { $assigned[$f.FullName] = $true }
        $arch = [string](Get-PV $pkg 'Archive' '')
        if ($arch) { foreach ($z in @(Find-PackageFiles -Root $InstallDir -Pattern $arch)) { $assigned[$z.FullName] = $true } }
    }
    foreach ($o in @(Get-ChildItem -Path $InstallDir -Recurse -File -Include '*OS*Optimization*Tool*.exe', '*OSOT*.exe' -ErrorAction SilentlyContinue)) { $assigned[$o.FullName] = $true }
    if ($script:EntryScript) { $assigned[$script:EntryScript] = $true }
    # the tool's own files, the OSOT Finalize helpers and the Teams files (used by Update-Teams) are not packages
    $toolFiles = '^(Modules\\|Scripts\\(Start-Menu|Test-SysprepReadiness)\.ps1$|OSOT\\(LGPO|sdelete64|sdelete)\.exe$|Teams\\(teamsbootstrapper\.exe|MSTeams-x64\.msix)$)'
    $ignore = @(Get-PV $ManifestObj 'Ignore' @())
    $exts = @('.exe', '.msi', '.msp', '.msu', '.cab', '.msix', '.msixbundle', '.appx', '.appxbundle', '.zip', '.ps1')
    Get-ChildItem -Path $InstallDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = Get-RelativePath $_.FullName
        ($exts -contains $_.Extension.ToLower()) -and -not $assigned.ContainsKey($_.FullName) -and
        $_.FullName -notmatch '\\Office\\Data\\' -and                     # files downloaded by ODT
        $rel -notmatch $toolFiles -and
        -not (@($ignore | Where-Object { $rel -match $_ }).Count)
    }
}

function Show-UnassignedFiles {
    param($ManifestObj)
    $un = @(Get-UnassignedFiles -ManifestObj $ManifestObj)
    if ($un.Count -eq 0) { Write-Log (T 'pkg.allAssigned' $InstallDir) OK; return }
    Write-Log (T 'pkg.unassigned' $InstallDir) WARN
    foreach ($f in $un) { Write-Log ("  {0}  [{1}]" -f (Get-RelativePath $f.FullName), (Get-FileVersionText $f)) }
}
