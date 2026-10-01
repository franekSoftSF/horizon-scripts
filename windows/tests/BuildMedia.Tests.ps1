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
