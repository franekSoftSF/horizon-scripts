# Manifest validation (-Mode Validate) and the Office XML templates.

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    Import-Module (Join-Path $Install 'Modules\VDI-ImageMaint\VDI-ImageMaint.psd1') -Force
    Mock -ModuleName VDI-ImageMaint Write-Log { }
    InModuleScope VDI-ImageMaint { Initialize-Strings -Language 'en' }

    function Get-Findings {
        # writes the manifest to TestDrive and returns the findings
        param([string]$Json)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'packages.json'), $Json)
        InModuleScope VDI-ImageMaint -Parameters @{ Root = $root } {
            $script:InstallDir = $Root; $script:Manifest = $null
            Test-Manifest -Path (Join-Path $Root 'packages.json')
        }
    }
    function Pkg {
        # minimal valid package with overrides (JSON fragments)
        param([string]$Extra = '')
        '{"Id":"Tool","Type":"exe","File":"Apps\\Tool*.exe","Detect":{"Type":"Always"}' + $Extra + '}'
    }
}

AfterAll { Remove-Module VDI-ImageMaint -Force -ErrorAction SilentlyContinue }

Describe 'Test-Manifest' {
    It 'accepts a minimal valid manifest (only the missing-file warning)' {
        $f = @(Get-Findings ('{"Packages":[' + (Pkg) + ']}'))
        @($f | Where-Object Level -eq 'ERR') | Should -BeNullOrEmpty
        @($f | Where-Object Level -eq 'WARN').Count | Should -Be 1
    }

    It 'finds <Case>' -ForEach @(
        @{ Case = 'a JSON syntax error';                 Json = '{"Packages":[ {"Id": } ]}';                                                    Level = 'ERR';  Path = 'packages.json' }
        @{ Case = '"false" in quotes (S6)';              Json = '{"Packages":[' + '{"Id":"Tool","Enabled":"false","Type":"exe","File":"x"}' + ']}'; Level = 'ERR';  Path = 'Packages[0] (Tool).Enabled' }
        @{ Case = 'a typo in a field name';             Json = '{"Packages":[' + '{"Id":"Tool","Enable":false,"Type":"exe","File":"x"}' + ']}'; Level = 'WARN'; Path = 'Packages[0] (Tool).Enable' }
        @{ Case = 'an unknown Type';                     Json = '{"Packages":[' + '{"Id":"Tool","Type":"zip","File":"x"}' + ']}';              Level = 'ERR';  Path = 'Packages[0] (Tool).Type' }
        @{ Case = 'a duplicate Id';                      Json = '{"Packages":[' + '{"Id":"A","File":"x"},{"Id":"A","File":"y"}' + ']}';        Level = 'ERR';  Path = 'Packages[1] (A)' }
        @{ Case = 'a missing File';                      Json = '{"Packages":[' + '{"Id":"A"}' + ']}';                                         Level = 'ERR';  Path = 'Packages[0] (A)' }
        @{ Case = 'Detect Registry without Value';       Json = '{"Packages":[' + '{"Id":"A","File":"x","Detect":{"Type":"Registry","Path":"HKLM:\\X","Name":"Y"}}' + ']}'; Level = 'ERR'; Path = 'Packages[0] (A).Detect' }
        @{ Case = 'an invalid PreferPath regex';         Json = '{"Packages":[' + '{"Id":"A","File":"x","PreferPath":"(["}' + ']}';            Level = 'ERR';  Path = 'Packages[0] (A).PreferPath' }
        @{ Case = 'an unknown {Variable} in Arguments';  Json = '{"Packages":[' + '{"Id":"A","File":"x","Arguments":"/s {Foo} {File}"}' + ']}'; Level = 'WARN'; Path = 'Packages[0] (A).Arguments' }
        @{ Case = 'Build referring to a missing Id';     Json = '{"Build":{"PostGeneralizePackages":["HorizonAgent"]},"Packages":[]}';      Level = 'ERR';  Path = 'Build.PostGeneralizePackages' }
        @{ Case = 'an unknown OSOT Finalize step';       Json = '{"Osot":{"Finalize":"0 1 12"},"Packages":[]}';                             Level = 'ERR';  Path = 'Osot.Finalize' }
        @{ Case = 'Compact (2) in Finalize';             Json = '{"Osot":{"Finalize":"0 2"},"Packages":[]}';                                Level = 'WARN'; Path = 'Osot.Finalize' }
        @{ Case = 'zeroing (7) in the Day-2 Finalize';   Json = '{"Osot":{"Finalize":"0 7"},"Packages":[]}';                                Level = 'WARN'; Path = 'Osot.Finalize' }
        @{ Case = 'OSOT removing the new Teams';         Json = '{"Osot":{"CommonOptions":["-storeapp","remove-all"]},"Packages":[]}';      Level = 'WARN'; Path = 'Osot.CommonOptions' }
        @{ Case = 'FSLogixConfig without a share';       Json = '{"Variables":{"FSLogixShare":""},"Packages":[' + '{"Id":"FSLogixConfig","Type":"ps1","File":"x.ps1"}' + ']}'; Level = 'ERR'; Path = 'Packages[0] (FSLogixConfig)' }
        @{ Case = 'an unknown Profile';                  Json = '{"Profile":"School","Packages":[]}';                                       Level = 'ERR';  Path = '$.Profile' }
    ) {
        $f = @(Get-Findings $Json)
        @($f | Where-Object { $_.Level -eq $Level -and $_.Path -eq $Path }).Count | Should -BeGreaterThan 0 -Because (($f | ForEach-Object { "$($_.Level) $($_.Path): $($_.Message)" }) -join ' | ')
    }

    It 'keeps --exclude MSTeams quiet' {
        $f = @(Get-Findings '{"Osot":{"CommonOptions":["-storeapp","remove-all","--exclude","Calculator","MSTeams"]},"Packages":[]}')
        @($f | Where-Object Path -eq 'Osot.CommonOptions') | Should -BeNullOrEmpty
    }

    It 'ignores _comment and $schema fields' {
        $f = @(Get-Findings '{"$schema":"x","_description":"y","Packages":[]}')
        $f | Should -BeNullOrEmpty
    }

    It 'the default manifest template has no errors' {
        $json = Get-Content (Join-Path $Install 'Modules\VDI-ImageMaint\Templates\packages.default.json') -Raw
        @(Get-Findings $json | Where-Object Level -eq 'ERR') | Should -BeNullOrEmpty
    }

    It 'the customer manifest packages.json has no errors' {
        $errors = InModuleScope VDI-ImageMaint -Parameters @{ Root = $Install } {
            $script:InstallDir = $Root; $script:Manifest = $null
            @(Test-Manifest -Path (Join-Path $Root 'packages.json') | Where-Object Level -eq 'ERR')
        }
        $errors | Should -BeNullOrEmpty
    }

    It 'the schema file is valid JSON and lists every package field the validator knows' {
        $schema = Get-Content (Join-Path $Install 'Modules\VDI-ImageMaint\Templates\packages.schema.json') -Raw | ConvertFrom-Json
        $fields = InModuleScope VDI-ImageMaint { @($script:ValidationRules.Package.Keys) }
        $inSchema = @($schema.definitions.package.properties.PSObject.Properties.Name)
        Compare-Object @($fields) $inSchema | Should -BeNullOrEmpty
    }
}

Describe 'Office XML templates' {
    BeforeDiscovery {
        $script:Templates = @(Get-ChildItem (Join-Path $PSScriptRoot '..\install\Office\Templates') -Filter '*.xml' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    }

    It 'has the 10 variants (2 licenses x pl, en, de, fr, pl+en)' {
        $names = @(Get-ChildItem (Join-Path $Install 'Office\Templates') -Filter '*.xml' | ForEach-Object Name)
        foreach ($p in 'O365ProPlusRetail', 'O365BusinessRetail') {
            foreach ($l in 'pl-pl', 'en-us', 'de-de', 'fr-fr', 'pl-pl_en-us') { $names | Should -Contain "$p-Shared_$l.xml" }
        }
    }

    It '<Name> is a shared VDI configuration matching its name' -ForEach $Templates {
        [xml]$x = Get-Content $Path -Raw
        $prod, $lang = ($Name -replace '\.xml$', '') -split '-Shared_'
        @($x.Configuration.Add.Product)[0].ID | Should -Be $prod
        $langs = @($x.SelectNodes("//Product[@ID='$prod']/Language") | ForEach-Object { $_.GetAttribute('ID') })
        ($langs -join '_') | Should -Be $lang
        $x.SelectSingleNode("//Property[@Name='SharedComputerLicensing']").GetAttribute('Value') | Should -Be '1'
        $x.Configuration.Updates.Enabled | Should -Be 'FALSE'
        $x.Configuration.Display.Level | Should -Be 'None'
        @($x.SelectNodes("//ExcludeApp[@ID='Teams']")).Count | Should -Be 1
        InModuleScope VDI-ImageMaint -Parameters @{ P = $Path } { Test-OdtInstallXml $P | Should -BeTrue }
    }
}
