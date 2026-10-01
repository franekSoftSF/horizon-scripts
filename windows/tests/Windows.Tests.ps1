# Windows release awareness (24H2/25H2/26H2/26H1), Horizon Agent support and feature-update filtering.

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    Import-Module (Join-Path $Install 'Modules\VDI-ImageMaint\VDI-ImageMaint.psd1') -Force
    Mock -ModuleName VDI-ImageMaint Write-Log { }
    InModuleScope VDI-ImageMaint { Initialize-Strings -Language 'en' }
}

AfterAll { Remove-Module VDI-ImageMaint -Force -ErrorAction SilentlyContinue }

Describe 'Get-WindowsRelease' {
    It 'build <Build> is <Release>' -ForEach @(
        @{ Build = 26100; Release = '24H2'; Vdi = $true }
        @{ Build = 26200; Release = '25H2'; Vdi = $true }
        @{ Build = 26300; Release = '26H2'; Vdi = $true }
        @{ Build = 28000; Release = '26H1'; Vdi = $false }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ B = $Build; R = $Release; V = $Vdi } {
            $rel = Get-WindowsRelease -Build $B
            $rel.Release | Should -Be $R
            $rel.Info.Vdi | Should -Be $V
        }
    }
    It 'reads the running system without errors' {
        InModuleScope VDI-ImageMaint { (Get-WindowsRelease).Build | Should -BeGreaterThan 0 }
    }
}

Describe 'Get-HorizonAgentVersion' {
    It '<Text> -> <Expected>' -ForEach @(
        @{ Text = 'Omnissa-Horizon-Agent-x86_64-2512-8.17.0-16560454767.exe'; Expected = '8.17.0' }
        @{ Text = 'Omnissa-Horizon-Agent-x86_64-2506-8.16.0-1234.exe';        Expected = '8.16.0' }
        @{ Text = '8.18.0.12345';                                             Expected = '8.18.0' }
        @{ Text = 'Horizon-Agent-x86-2603.1.exe';                             Expected = '8.18.1' }
        @{ Text = 'setup.exe';                                                Expected = '' }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ Text = $Text; Expected = $Expected } {
            Get-HorizonAgentVersion $Text | Should -Be $Expected
        }
    }
    It 'shows the marketing name' {
        InModuleScope VDI-ImageMaint {
            Get-HorizonMarketingName '8.16.0' | Should -Be '2506'
            Get-HorizonMarketingName '8.17.1' | Should -Be '2512.1'
        }
    }
}

Describe 'Test-HorizonAgentSupport (KB 78714)' {
    It 'agent <Agent> on build <Build> -> <Expected>' -ForEach @(
        @{ Agent = '8.16.0'; Build = 26100; Expected = 'ok' }        # 2506 on 24H2
        @{ Agent = '8.16.0'; Build = 26200; Expected = 'old' }       # 2506 on 25H2 - not supported
        @{ Agent = '8.17.0'; Build = 26200; Expected = 'ok' }        # 2512 on 25H2
        @{ Agent = '8.19.0'; Build = 26300; Expected = 'unlisted' }  # 26H2 not in the matrix yet
        @{ Agent = '8.19.0'; Build = 28000; Expected = 'novdi' }
        @{ Agent = '';       Build = 26200; Expected = 'unknown' }
        @{ Agent = '8.19.0'; Build = 19045; Expected = 'unknown' }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ A = $Agent; B = $Build; E = $Expected } {
            Test-HorizonAgentSupport -AgentVersion $A -Release (Get-WindowsRelease -Build $B) | Should -Be $E
        }
    }
    It 'names the minimum version in the message' {
        InModuleScope VDI-ImageMaint {
            Get-HorizonAgentSupportText -AgentVersion '8.16.0' -Release (Get-WindowsRelease -Build 26200) | Should -Match '2506.*25H2.*2512'
            Get-HorizonAgentSupportText -AgentVersion '8.17.0' -Release (Get-WindowsRelease -Build 26200) | Should -Be ''
        }
    }
}

Describe 'Test-FeatureUpdate' {
    It '<Title> -> <Expected>' -ForEach @(
        @{ Title = 'Feature update to Windows 11, version 26H2'; Cat = '';                                      Expected = $true }
        @{ Title = 'Windows 11, version 26H2';                   Cat = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'; Expected = $true }
        @{ Title = 'Aktualizacja funkcji do systemu Windows 11, wersja 26H2'; Cat = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5';                         Expected = $true }
        @{ Title = '2026-09 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5124010)'; Cat = ''; Expected = $false }
        @{ Title = 'Security Intelligence Update for Microsoft Defender Antivirus'; Cat = '';                   Expected = $false }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ Title = $Title; Cat = $Cat; E = $Expected } {
            $u = [pscustomobject]@{ Title = $Title; Categories = @($(if ($Cat) { [pscustomobject]@{ CategoryID = $Cat } })) }
            Test-FeatureUpdate $u | Should -Be $E
        }
    }
}

Describe 'Horizon Agent profile defaults' {
    It '<Name> contains Core and NGVC and only known options' -ForEach @(
        @{ Name = 'University' }, @{ Name = 'Business' }, @{ Name = 'Graphics' }
    ) {
        InModuleScope VDI-ImageMaint -Parameters @{ N = $Name } {
            $f = $script:HorizonAgentProfileFeatures[$N] -split ','
            $f | Should -Contain 'Core'
            $f | Should -Contain 'NGVC'
            foreach ($x in $f) { $script:HorizonAgentFeatures | Should -Contain $x }
        }
    }
}
