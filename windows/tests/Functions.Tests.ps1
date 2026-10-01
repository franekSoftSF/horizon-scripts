# Unit tests of the VDI-ImageMaint module functions (no admin rights, no network, no system changes
# except a temporary HKCU test key).

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    Import-Module (Join-Path $Install 'Modules\VDI-ImageMaint\VDI-ImageMaint.psd1') -Force
    Mock -ModuleName VDI-ImageMaint Write-Log { }
    InModuleScope VDI-ImageMaint { Initialize-Strings -Language 'en' }
}

AfterAll {
    Remove-Module VDI-ImageMaint -Force -ErrorAction SilentlyContinue
}

Describe 'T (localized messages)' {
    It 'formats arguments in English and Polish' {
        InModuleScope VDI-ImageMaint {
            Initialize-Strings -Language 'pl'
            T 'pkg.summary' 3 1 | Should -Be 'Pakiety: zainstalowano 3, błędy 1'
            Initialize-Strings -Language 'en'
            T 'pkg.summary' 3 1 | Should -Be 'Packages: installed 3, errors 1'
        }
    }
    It 'returns [key] for an unknown key instead of failing' {
        InModuleScope VDI-ImageMaint { T 'no.such.key' | Should -Be '[no.such.key]' }
    }
}

Describe 'ConvertTo-Version' {
    It '<Text> -> <Expected>' -ForEach @(
        @{ Text = '8.16.0.16560454767'; Expected = '8.16.0.0' }   # Horizon build number > Int32 is dropped
        @{ Text = '13.1.5-25544008';    Expected = '13.1.5.0' }
        @{ Text = 'v1.2';               Expected = '1.2.0.0' }
        @{ Text = '26.153.0809.0004';   Expected = '26.153.809.4' }
        @{ Text = '2506';               Expected = '' }           # single number is not a version
        @{ Text = '';                   Expected = '' }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ Text = $Text; Expected = $Expected } {
            "$(ConvertTo-Version $Text)" | Should -Be $Expected
        }
    }
    It 'compares 8.16.0 and 8.16.0.0 as equal' {
        InModuleScope VDI-ImageMaint { (ConvertTo-Version '8.16.0') -eq (ConvertTo-Version '8.16.0.0') | Should -BeTrue }
    }
}

Describe 'Get-NormalizedName' {
    It 'gives x64 and x86 variants of a product the same name' {
        InModuleScope VDI-ImageMaint {
            Get-NormalizedName 'Mozilla Firefox (x64 en-US)' | Should -Be 'mozilla firefox'
            Get-NormalizedName 'Mozilla Firefox (x86 en-US)' | Should -Be 'mozilla firefox'
        }
    }
    It 'drops version numbers and keeps the product words' {
        InModuleScope VDI-ImageMaint {
            Get-NormalizedName '7-Zip 24.08 (x64)' | Should -Be '7 zip'
            Get-NormalizedName 'Notepad++ (64-bit x64)' | Should -Be 'notepad++'
        }
    }
}

Describe 'Expand-PkgString' {
    It 'replaces known variables and leaves unknown ones' {
        InModuleScope VDI-ImageMaint {
            Expand-PkgString '-VHDLocations ''{FSLogixShare}'' /log "{Log}" {Unknown}' @{ FSLogixShare = '\\fs01\Profiles$'; Log = 'C:\x.log' } |
                Should -Be '-VHDLocations ''\\fs01\Profiles$'' /log "C:\x.log" {Unknown}'
        }
    }
}

Describe 'ConvertFrom-WingetTable' {
    BeforeAll {
        $fmt = '{0,-30}{1,-26}{2,-14}{3,-14}{4}'
        $script:Table = @(
            '   - ',
            ($fmt -f 'Name', 'Id', 'Version', 'Available', 'Source'),
            ('-' * 94),
            ($fmt -f 'Mozilla Firefox (x64 pl)', 'Mozilla.Firefox.pl', '130.0', '131.0.2', 'winget'),
            ($fmt -f '7-Zip 24.08 (x64)', '7zip.7zip', '24.08', '24.09', 'winget'),
            ($fmt -f 'Zażółć Gęślą Jaźń', 'Vendor.PolishApp', '1.0', '2.0', 'winget'),
            '3 upgrades available.'
        )
    }
    It 'reads every row by column position (header language does not matter)' {
        InModuleScope VDI-ImageMaint -Parameters @{ Table = $Table } {
            $rows = @(ConvertFrom-WingetTable -Lines $Table)
            $rows.Count | Should -Be 3
            $rows[0].Id | Should -Be 'Mozilla.Firefox.pl'
            $rows[0].Version | Should -Be '130.0'
            $rows[0].Available | Should -Be '131.0.2'
            $rows[2].Name | Should -Be 'Zażółć Gęślą Jaźń'
            $rows[1].Source | Should -Be 'winget'
        }
    }
    It 'returns nothing when winget prints no table' {
        InModuleScope VDI-ImageMaint { @(ConvertFrom-WingetTable -Lines @('No installed package found matching input criteria.')).Count | Should -Be 0 }
    }
    It 'classifies Store apps, exclusions and VDI components as skip' {
        InModuleScope VDI-ImageMaint -Parameters @{ Table = $Table } {
            Mock Invoke-Winget { $Table }
            $script:WingetIncludeUnknown = $false
            $script:WingetStoreIds = @('Microsoft.Teams')
            $script:WingetExcludeIds = @('7zip.7zip')
            $script:WingetExcludePattern = 'PolishApp'
            $p = @(Get-WingetUpgrades)
            ($p | Where-Object Id -eq 'Mozilla.Firefox.pl').Action | Should -Be 'update'
            ($p | Where-Object Id -eq '7zip.7zip').Action | Should -Be 'skip'
            ($p | Where-Object Id -eq 'Vendor.PolishApp').Action | Should -Be 'skip'
        }
    }
}

Describe 'ConvertTo-ArgumentText' {
    It 'writes switches, quoted values, arrays and skips passwords and excluded keys' {
        InModuleScope VDI-ImageMaint {
            $p = [ordered]@{
                Mode          = 'Seal'
                InstallDir    = "C:\my install"
                WingetIds     = @('A.B', "it's")
                Force         = [System.Management.Automation.SwitchParameter]::Present
                Cleanup       = [System.Management.Automation.SwitchParameter]$false
                AdminPassword = (ConvertTo-SecureString 'x' -AsPlainText -Force)
            }
            ConvertTo-ArgumentText -Params $p -Exclude @('Mode') |
                Should -Be "-InstallDir 'C:\my install' -WingetIds 'A.B','it''s' -Force"
        }
    }
    It 'round-trips through a real PowerShell command line' {
        InModuleScope VDI-ImageMaint {
            $text = ConvertTo-ArgumentText -Params ([ordered]@{ A = "x 'y'"; B = @('1', '2') })
            $sb = [scriptblock]::Create("function f { param([string]`$A, [string[]]`$B) `"`$A|`$(`$B -join ',')`" }; f $text")
            & $sb | Should -Be "x 'y'|1,2"
        }
    }
}

Describe 'Format-Json' {
    It 'indents with two spaces, un-escapes the \u003c \u003e \u0026 \u0027 escapes and keeps the data' {
        InModuleScope VDI-ImageMaint {
            $obj = [pscustomobject]@{ Name = 'a <b> & ''c'''; List = @(1, 2); Sub = [pscustomobject]@{ X = 'y' } }
            $out = Format-Json ($obj | ConvertTo-Json -Depth 5)
            $out | Should -Match '"Name": "a <b> & ''c''"'
            $out | Should -Match '(?m)^  "Sub": \{\r?$'
            $out | Should -Match '(?m)^    "X": "y"\r?$'
            ($out | ConvertFrom-Json).Sub.X | Should -Be 'y'
        }
    }
}

Describe 'New-OdtConfigXml' {
    It 'creates a VDI configuration: SCA, no updates, silent, one language + proofing tools' {
        InModuleScope VDI-ImageMaint {
            [xml]$x = New-OdtConfigXml -Product 'O365ProPlusRetail' -Channel 'MonthlyEnterprise' -Language 'pl-pl' `
                -ExtraMode 'Proofing' -ExtraLanguage 'en-us' -ExcludeApps @('Teams', 'Lync', 'Teams')
            $x.Configuration.Add.Channel | Should -Be 'MonthlyEnterprise'
            @($x.Configuration.Add.Product)[0].ID | Should -Be 'O365ProPlusRetail'
            @($x.Configuration.Add.Product)[1].ID | Should -Be 'ProofingTools'
            @($x.SelectNodes('//Product[@ID="O365ProPlusRetail"]/Language')).Count | Should -Be 1
            @($x.SelectNodes('//ExcludeApp[@ID="Teams"]')).Count | Should -Be 1
            $x.SelectSingleNode('//Property[@Name="SharedComputerLicensing"]').GetAttribute('Value') | Should -Be '1'
            $x.Configuration.Updates.Enabled | Should -Be 'FALSE'
            $x.Configuration.Display.Level | Should -Be 'None'
        }
    }
}

Describe 'New-UnattendXml' {
    BeforeAll {
        $script:Cfg = [ordered]@{ TimeZone = 'Central European Standard Time'; InputLocale = 'pl-PL'; SystemLocale = 'pl-PL'
            UILanguage = 'en-US'; UserLocale = 'pl-PL'; ComputerName = 'GOLD&W11'; SkipRearm = $true
            PersistAllDeviceInstalls = $true; AutoLogonCount = 10 }
    }
    It 'is valid XML with all passes, escaped values and WSIM-encoded passwords' {
        InModuleScope VDI-ImageMaint -Parameters @{ Cfg = $Cfg } {
            Mock Get-BuiltinAdminName { 'Administrator' }
            $secret = ConvertTo-SecureString 'Pa$$w0rd!' -AsPlainText -Force
            [xml]$x = New-UnattendXml -Cfg $Cfg -Password $secret -FirstLogonCommand 'powershell.exe -File "C:\install\VDI-ImageMaint.ps1" -Mode PostGeneralize'
            $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            @($x.SelectNodes('//u:settings', $ns) | ForEach-Object pass) | Should -Be @('generalize', 'specialize', 'oobeSystem')
            $x.SelectSingleNode('//u:ComputerName', $ns).InnerText | Should -Be 'GOLD&W11'
            $x.SelectSingleNode('//u:SkipRearm', $ns).InnerText | Should -Be '1'
            $x.SelectSingleNode('//u:CommandLine', $ns).InnerText | Should -Match '-Mode PostGeneralize$'
            $b = [Convert]::FromBase64String($x.SelectSingleNode('//u:AutoLogon/u:Password/u:Value', $ns).InnerText)
            [Text.Encoding]::Unicode.GetString($b) | Should -Be 'Pa$$w0rd!Password'
            $b = [Convert]::FromBase64String($x.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns).InnerText)
            [Text.Encoding]::Unicode.GetString($b) | Should -Be 'Pa$$w0rd!AdministratorPassword'
        }
    }
    It 'leaves out SkipRearm when it is off' {
        InModuleScope VDI-ImageMaint -Parameters @{ Cfg = $Cfg } {
            Mock Get-BuiltinAdminName { 'Administrator' }
            $c = [ordered]@{}; foreach ($k in $Cfg.Keys) { $c[$k] = $Cfg[$k] }; $c.SkipRearm = $false
            (New-UnattendXml -Cfg $c -Password (ConvertTo-SecureString 'x' -AsPlainText -Force) -FirstLogonCommand 'x') | Should -Not -Match 'SkipRearm'
        }
    }
}

Describe 'Resolve-OdtConfig' {
    It 'picks the install XML next to setup.exe and ignores Uninstall.xml' {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = "$TestDrive\odt" } {
            New-Item -ItemType Directory -Path "$Root\Office" -Force | Out-Null
            Set-Content "$Root\Office\setup.exe" 'x'
            Set-Content "$Root\Office\Configuration_x64.xml" '<Configuration><Add Channel="Current"/></Configuration>'
            Set-Content "$Root\Office\Uninstall.xml" '<Configuration><Remove All="TRUE"/></Configuration>'
            $script:InstallDir = $Root
            $pkg = '{ "Id": "Office365", "Type": "odt" }' | ConvertFrom-Json
            Resolve-OdtConfig $pkg (Get-Item "$Root\Office\setup.exe") | Should -Be "$Root\Office\Configuration_x64.xml"
            Remove-Item "$Root\Office\Configuration_x64.xml"
            Resolve-OdtConfig $pkg (Get-Item "$Root\Office\setup.exe") | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-PackagePlan' {
    BeforeAll {
        $script:Root = "$TestDrive\plan"
        New-Item -ItemType Directory -Path "$Root\Apps" -Force | Out-Null
        Set-Content "$Root\Apps\Tool-setup.exe" 'x'
        $script:RegKey = 'HKCU:\Software\VDI-ImageMaint-Tests'
        New-Item -Path $RegKey -Force | Out-Null
        New-ItemProperty -Path $RegKey -Name 'ConfigVersion' -Value '2' -PropertyType String -Force | Out-Null
    }
    AfterAll { Remove-Item -Path 'HKCU:\Software\VDI-ImageMaint-Tests' -Recurse -Force -ErrorAction SilentlyContinue }

    It '<Case>' -ForEach @(
        @{ Case = 'newer package -> update';                 Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","Detect":{"Type":"Uninstall","Name":"^Tool$"}}'; Installed = '0.9'; Action = 'update' }
        @{ Case = 'same version -> current';                 Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","Detect":{"Type":"Uninstall","Name":"^Tool$"}}'; Installed = '1.0'; Action = 'current' }
        @{ Case = 'not installed -> install';                Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","Detect":{"Type":"Uninstall","Name":"^Tool$"}}'; Installed = '';    Action = 'install' }
        @{ Case = 'not installed + RequireInstalled -> skip'; Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","RequireInstalled":true,"Detect":{"Type":"Uninstall","Name":"^Tool$"}}'; Installed = ''; Action = 'skip' }
        @{ Case = 'disabled -> skip';                        Json = '{"Id":"Tool","Enabled":false,"Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","Detect":{"Type":"Uninstall","Name":"^Tool$"}}'; Installed = '0.9'; Action = 'skip' }
        @{ Case = 'file missing -> missing';                 Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Other*.exe","Detect":{"Type":"Always"}}'; Installed = ''; Action = 'missing' }
        @{ Case = 'Detect Always -> install';                Json = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Detect":{"Type":"Always"}}'; Installed = ''; Action = 'install' }
        @{ Case = 'Registry value equal -> current';         Json = '{"Id":"Cfg","Type":"exe","File":"Apps\\Tool-*.exe","Detect":{"Type":"Registry","Path":"HKCU:\\Software\\VDI-ImageMaint-Tests","Name":"ConfigVersion","Value":"2"}}'; Installed = ''; Action = 'current' }
        @{ Case = 'Registry value differs -> install';       Json = '{"Id":"Cfg","Type":"exe","File":"Apps\\Tool-*.exe","Detect":{"Type":"Registry","Path":"HKCU:\\Software\\VDI-ImageMaint-Tests","Name":"ConfigVersion","Value":"3"}}'; Installed = ''; Action = 'install' }
        @{ Case = 'Registry without Path does not throw';    Json = '{"Id":"Cfg","Type":"exe","File":"Apps\\Tool-*.exe","Detect":{"Type":"Registry","Name":"X","Value":"1"}}'; Installed = ''; Action = 'install' }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = $Root; Json = $Json; Installed = $Installed; Action = $Action } {
            $script:InstallDir = $Root; $script:PackageIds = $null; $script:ForceInstallIds = @()
            $apps = @(if ($Installed) { [pscustomobject]@{ Name = 'Tool'; Version = $Installed } })
            (Get-PackagePlan -Pkg ($Json | ConvertFrom-Json) -Installed $apps).Action | Should -Be $Action
        }
    }

    It 'PostGeneralize forces a disabled update-only agent to a fresh install' {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = $Root } {
            $script:InstallDir = $Root; $script:PackageIds = @('Tool'); $script:ForceInstallIds = @('Tool')
            $pkg = '{"Id":"Tool","Enabled":false,"RequireInstalled":true,"Type":"exe","File":"Apps\\Tool-*.exe","Version":"1.0","Detect":{"Type":"Uninstall","Name":"^Tool$"}}' | ConvertFrom-Json
            (Get-PackagePlan -Pkg $pkg -Installed @()).Action | Should -Be 'install'
            $script:ForceInstallIds = @(); $script:PackageIds = $null
        }
    }

    It '-PackageIds skips the other packages' {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = $Root } {
            $script:InstallDir = $Root; $script:PackageIds = @('SomethingElse'); $script:ForceInstallIds = @()
            $pkg = '{"Id":"Tool","Type":"exe","File":"Apps\\Tool-*.exe","Detect":{"Type":"Always"}}' | ConvertFrom-Json
            (Get-PackagePlan -Pkg $pkg -Installed @()).Action | Should -Be 'skip'
            $script:PackageIds = $null
        }
    }
}

Describe 'Get-BuildConfig' {
    It 'uses the manifest values and falls back to the system for empty ones' {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = "$TestDrive\build" } {
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            Set-Content "$Root\packages.json" '{ "Build": { "TimeZone": "", "InputLocale": "de-DE", "SkipRearm": true } }' -Encoding UTF8
            $script:InstallDir = $Root; $script:Manifest = $null
            $c = Get-BuildConfig
            $c.TimeZone | Should -Be (Get-TimeZone).Id
            $c.InputLocale | Should -Be 'de-DE'
            $c.SkipRearm | Should -BeTrue
            $c.PostGeneralizePackages | Should -Contain 'HorizonAgent'
        }
    }
}

Describe 'Seal baseline' {
    AfterAll { Remove-Item -Path 'HKCU:\Software\VDI-ImageMaint-Tests-Seal' -Recurse -Force -ErrorAction SilentlyContinue }
    It 'records the original value once and never overwrites it (B4)' {
        InModuleScope VDI-ImageMaint {
            $key = 'HKCU:\Software\VDI-ImageMaint-Tests-Seal'
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name 'NoAutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null
            $state = New-SealState
            $def = @{ Path = $key; Name = 'NoAutoUpdate'; Value = 1 }
            Add-PolicyBaseline -Def $def -State $state
            Set-ItemProperty -Path $key -Name 'NoAutoUpdate' -Value 1        # e.g. OSOT changed it
            Add-PolicyBaseline -Def $def -State $state
            @($state.Registry).Count | Should -Be 1
            $state.Registry[0].Existed | Should -BeTrue
            $state.Registry[0].OldValue | Should -Be 0
            $state.Registry[0].OldKind | Should -Be 'DWord'
            Add-PolicyBaseline -Def @{ Path = $key; Name = 'Missing'; Value = 1 } -State $state
            ($state.Registry | Where-Object Name -eq 'Missing').Existed | Should -BeFalse
        }
    }
}

Describe 'Download helpers' {
    It 'Install-DownloadedFile: new, then current, and removes older versions' {
        InModuleScope VDI-ImageMaint -Parameters @{ Root = "$TestDrive\dl" } {
            New-Item -ItemType Directory -Path "$Root\Horizon" -Force | Out-Null
            Set-Content "$Root\Horizon\VMware-tools-12.0.0-1-x64.exe" 'old'
            Set-Content "$Root\new.exe" 'new'
            $script:InstallDir = $Root
            Install-DownloadedFile -Source "$Root\new.exe" -Folder "$Root\Horizon" -Name 'VMware-tools-13.1.5-2-x64.exe' -ReplacePattern 'VMware-tools-*.exe' | Should -Be 'new'
            Test-Path "$Root\Horizon\VMware-tools-12.0.0-1-x64.exe" | Should -BeFalse
            Install-DownloadedFile -Source "$Root\new.exe" -Folder "$Root\Horizon" -Name 'VMware-tools-13.1.5-2-x64.exe' | Should -Be 'current'
        }
    }
    It 'Get-IndexFileUrl picks the newest file of the listing' {
        InModuleScope VDI-ImageMaint {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<a href="VMware-tools-13.0.10-1-x64.exe">a</a> <a href="VMware-tools-13.1.5-2-x64.exe">b</a> <a href="VMware-tools-9.9.9-3-x64.exe">c</a>' } }
            Get-IndexFileUrl -Url 'https://example.test/x64/' -Pattern 'VMware-tools-[\d.]+-\d+-(x64|x86_64)\.exe' |
                Should -Be 'https://example.test/x64/VMware-tools-13.1.5-2-x64.exe'
        }
    }
    It 'Resolve-ReleaseUrl puts the current release into {Release}; Url without ReleaseUrl stays as is' {
        InModuleScope VDI-ImageMaint {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<packages><past>2026-06/R</past><present>2026-09/R</present></packages>' } }
            $d = '{"Url":"https://example.test/release/{Release}/R/eclipse-java-{Release}-R-win32-x86_64.zip","ReleaseUrl":"https://example.test/release.xml","ReleasePattern":"<present>(\\d{4}-\\d{2})/R</present>"}' | ConvertFrom-Json
            Resolve-ReleaseUrl $d | Should -Be 'https://example.test/release/2026-09/R/eclipse-java-2026-09-R-win32-x86_64.zip'
            Resolve-ReleaseUrl ('{"Url":"https://example.test/a.exe"}' | ConvertFrom-Json) | Should -Be 'https://example.test/a.exe'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<packages></packages>' } }
            { Resolve-ReleaseUrl $d } | Should -Throw
        }
    }
    It 'Assert-Signature accepts the expected publisher and rejects anything else' {
        InModuleScope VDI-ImageMaint {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } } }
            { Assert-Signature -Path 'C:\x.exe' -Signer 'O=Microsoft Corporation' } | Should -Not -Throw
            { Assert-Signature -Path 'C:\x.exe' -Signer 'VMware|Broadcom' } | Should -Throw
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
            { Assert-Signature -Path 'C:\x.exe' -Signer 'O=Microsoft Corporation' } | Should -Throw
            { Assert-Signature -Path 'C:\x.msix' -Signer '' } | Should -Not -Throw
        }
    }
}

Describe 'Entry point and modes' {
    It 'every -Mode of VDI-ImageMaint.ps1 has a handler in Invoke-VdiImageMaint' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Install 'VDI-ImageMaint.ps1'), [ref]$null, [ref]$null)
        $modeParam = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
        $vs = $modeParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $modes = @($vs.PositionalArguments | ForEach-Object { $_.Value })
        $pub = Get-Content (Join-Path $Install 'Modules\VDI-ImageMaint\Public\Invoke-VdiImageMaint.ps1') -Raw
        $handled = @([regex]::Matches($pub, "(?m)^\s*'(\w+)'\s*\{") | ForEach-Object { $_.Groups[1].Value })
        Compare-Object $modes $handled | Should -BeNullOrEmpty
    }
    It 'the restart signal ends a run without an error' {
        InModuleScope VDI-ImageMaint {
            { Stop-ForRestart } | Should -Throw -ExpectedMessage $script:RestartSignal
        }
    }
    It 'Get-ResumeCommand forwards the given parameters and increments the round' {
        InModuleScope VDI-ImageMaint {
            $script:EntryScript = 'C:\install\VDI-ImageMaint.ps1'
            $script:BoundParams = [ordered]@{ Mode = 'Update'; AutoReboot = [System.Management.Automation.SwitchParameter]::Present; Language = 'pl'; ResumeRound = 1 }
            $script:ResumeRound = 1
            Get-ResumeCommand | Should -Be "& 'C:\install\VDI-ImageMaint.ps1' -Mode 'Update' -AutoReboot -Language 'pl' -ResumeRound 2"
        }
    }
}
