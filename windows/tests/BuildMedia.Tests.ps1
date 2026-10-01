# New-BuildMedia.ps1: autounattend.xml for an unattended install into audit mode, and the build ISO.
# The script ends with 'exit', so it runs in a separate Windows PowerShell process.

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    $script:Script  = Join-Path $Install 'Scripts\New-BuildMedia.ps1'
    $script:Ps51    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Ns      = @{ u = 'urn:schemas-microsoft-com:unattend' }

    function New-Answer {
        # runs -XmlOnly into a fresh TestDrive folder and returns the parsed XML
        param([string[]]$Extra = @())
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $out = & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Script -XmlOnly -OutFile (Join-Path $dir 'VDI-Build.iso') -Language en @Extra 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out | Out-String) }
        [xml](Get-Content (Join-Path $dir 'autounattend.xml') -Raw)
    }
    function Get-Text {
        param([xml]$Xml, [string]$XPath)
        @($Xml | Select-Xml $XPath -Namespace $Ns | ForEach-Object { $_.Node.InnerText })
    }
}

Describe 'New-BuildMedia autounattend.xml' {
    BeforeAll { $script:X = New-Answer @('-Edition', 'Education', '-UILanguage', 'pl-PL') }

    It 'has the four passes and ends in audit mode' {
        (@($X | Select-Xml '//u:settings' -Namespace $Ns | ForEach-Object { $_.Node.GetAttribute('pass') }) -join ',') | Should -Be 'windowsPE,specialize,oobeSystem,auditUser'
        Get-Text $X "//u:settings[@pass='oobeSystem']//u:Reseal/u:Mode" | Should -Be 'Audit'
    }
    It 'selects the edition by name and the matching generic KMS key' {
        Get-Text $X '//u:MetaData/u:Value' | Should -Be 'Windows 11 Education'
        Get-Text $X '//u:ProductKey/u:Key' | Should -Be 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
    }
    It 'uses the requested setup language' {
        Get-Text $X '//u:SetupUILanguage/u:UILanguage' | Should -Be 'pl-PL'
    }
    It 'partitions disk 0 for UEFI and installs to partition 3' {
        (Get-Text $X '//u:CreatePartition/u:Type') -join ',' | Should -Be 'EFI,MSR,Primary'
        Get-Text $X '//u:InstallTo/u:PartitionID' | Should -Be '3'
    }
    It 'bypasses the TPM check, prevents device encryption and Store auto-updates' {
        $paths = (Get-Text $X '//u:Path') -join "`n"
        $paths | Should -Match 'LabConfig /v BypassTPMCheck'
        $paths | Should -Match 'PreventDeviceEncryption /t REG_DWORD /d 1'
        $paths | Should -Match 'WindowsStore /v AutoDownload /t REG_DWORD /d 2'
    }
    It 'copies C:\install from the tagged drive, then starts the menu' {
        $cmds = Get-Text $X "//u:settings[@pass='auditUser']//u:Path"
        $cmds[0] | Should -Match 'vdi-build\.tag robocopy %d:\\install C:\\install'
        $cmds[1] | Should -Match 'START\.cmd'
    }
    It 'contains no password' {
        @($X | Select-Xml '//u:Password|//u:AdministratorPassword|//u:AutoLogon' -Namespace $Ns) | Should -BeNullOrEmpty
    }
}

Describe 'New-BuildMedia options' {
    It '-WithVtpm leaves out the TPM bypass' {
        $x = New-Answer @('-WithVtpm')
        (Get-Text $x '//u:Path') -join "`n" | Should -Not -Match 'LabConfig'
    }
    It '-AutoStart None only copies' {
        $x = New-Answer @('-AutoStart', 'None')
        @(Get-Text $x "//u:settings[@pass='auditUser']//u:Path").Count | Should -Be 1
    }
    It '-AutoStart Update starts the update with reboots' {
        $x = New-Answer @('-AutoStart', 'Update')
        (Get-Text $x "//u:settings[@pass='auditUser']//u:Path")[1] | Should -Match '-Mode Update -AutoReboot'
    }
    It '-ImageName overrides the edition name and is XML-escaped' {
        $x = New-Answer @('-ImageName', 'Windows 11 Enterprise & more')
        Get-Text $x '//u:MetaData/u:Value' | Should -Be 'Windows 11 Enterprise & more'
    }
}

Describe 'New-BuildMedia ISO' {
    It 'writes a UDF ISO with -ScriptsOnly' {
        $iso = Join-Path $TestDrive 'VDI-Build.iso'
        $out = & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Script -OutFile $iso -ScriptsOnly -Language en 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        (Get-Item $iso).Length | Should -BeGreaterThan 100KB
        # UDF descriptor "NSR02" in the volume recognition sequence (sectors 16+)
        $bytes = [IO.File]::ReadAllBytes($iso)
        [Text.Encoding]::ASCII.GetString($bytes, 16 * 2048, 8 * 2048) | Should -Match 'NSR0[23]'
    }
}

Describe 'New-BuildMedia -Method OSDCloud answer file' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'osd'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $out = & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Script -Method OSDCloud -XmlOnly -OutFile (Join-Path $dir 'x.iso') -UILanguage pl-PL -Language en 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out | Out-String) }
        $script:O = [xml](Get-Content (Join-Path $dir 'unattend.xml') -Raw)
    }
    It 'has no windowsPE pass (OSDCloud applies the image) and still ends in audit mode' {
        (@($O | Select-Xml '//u:settings' -Namespace $Ns | ForEach-Object { $_.Node.GetAttribute('pass') }) -join ',') | Should -Be 'specialize,oobeSystem,auditUser'
        Get-Text $O '//u:Reseal/u:Mode' | Should -Be 'Audit'
    }
    It 'only starts the menu in auditUser (C:\install is copied in WinPE)' {
        $cmds = @(Get-Text $O "//u:settings[@pass='auditUser']//u:Path")
        $cmds.Count | Should -Be 1
        $cmds[0] | Should -Match 'START\.cmd'
        Get-Text $O "//u:settings[@pass='auditUser']//u:Order" | Should -Be '1'
    }
    It 'rejects Pro Education and languages OSDCloud does not offer' {
        # the script writes the error to stderr - Windows PowerShell 5.1 would turn it into an exception
        $ErrorActionPreference = 'Continue'
        & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Script -Method OSDCloud -XmlOnly -Edition ProEducation -OutFile (Join-Path $TestDrive 'y.iso') -Language en 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Script -Method OSDCloud -XmlOnly -UILanguage xx-XX -OutFile (Join-Path $TestDrive 'y.iso') -Language en 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'Invoke-GoldenVm -ValidateOnly' {
    BeforeAll {
        $script:Vm = Join-Path $Install 'Scripts\Invoke-GoldenVm.ps1'
        $script:Root = Join-Path $TestDrive 'vc'
        $script:Inst = Join-Path $Root 'install'
        New-Item -ItemType Directory -Path $Inst -Force | Out-Null
        Copy-Item (Join-Path $Install 'vcenter.example.json') (Join-Path $Inst 'vcenter.json')
        Set-Content -Path (Join-Path $Root 'VDI-Build.iso') -Value 'x'
    }
    It 'accepts the example config and prints the two CD drives' {
        $out = & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Vm -Action New -InstallDir $Inst -ValidateOnly -Language en 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'CD 1: \[ds-iso\] Windows/Win11'
        $out | Should -Match 'CD 2: \[ds-golden\] ISO/VDI-ImageMaint/VDI-Build\.iso'
    }
    It 'fails without vcenter.json' {
        $ErrorActionPreference = 'Continue'
        & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Vm -Action New -InstallDir (Join-Path $TestDrive 'none') -ValidateOnly -Language en 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
    It 'fails when the build ISO is missing (OSDCloud)' {
        $ErrorActionPreference = 'Continue'
        & $Ps51 -NoProfile -ExecutionPolicy Bypass -File $Vm -Action New -Method OSDCloud -InstallDir $Inst -ValidateOnly -Language en 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}