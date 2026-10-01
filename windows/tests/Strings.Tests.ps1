# English / Polish string tables and source file hygiene.

BeforeAll {
    $script:Install    = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    $script:ModuleRoot = Join-Path $Install 'Modules\VDI-ImageMaint'

    function Read-StringTable {
        param([string]$Culture)
        $table = @{}; $dup = @()
        foreach ($f in Get-ChildItem (Join-Path $ModuleRoot $Culture) -Filter '*.psd1') {
            $d = Import-PowerShellDataFile $f.FullName
            foreach ($k in $d.Keys) { if ($table.ContainsKey($k)) { $dup += "$k ($($f.Name))" }; $table[$k] = $d[$k] }
        }
        [pscustomobject]@{ Table = $table; Duplicates = $dup }
    }
    function Get-Placeholders { param([string]$Text) (@([regex]::Matches($Text, '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',') }

    $script:En = Read-StringTable 'en-US'
    $script:Pl = Read-StringTable 'pl-PL'
}

Describe 'Module string tables (en-US / pl-PL)' {
    It 'has no duplicate keys across the area files' {
        @($En.Duplicates) + @($Pl.Duplicates) | Should -BeNullOrEmpty
    }

    It 'has the same area files in both cultures' {
        $a = @(Get-ChildItem (Join-Path $ModuleRoot 'en-US') -Filter '*.psd1' | ForEach-Object Name)
        $b = @(Get-ChildItem (Join-Path $ModuleRoot 'pl-PL') -Filter '*.psd1' | ForEach-Object Name)
        Compare-Object $a $b | Should -BeNullOrEmpty
    }

    It 'has the same keys in English and Polish' {
        Compare-Object @($En.Table.Keys) @($Pl.Table.Keys) | Should -BeNullOrEmpty
    }

    It 'uses the same {n} placeholders in both languages' {
        $bad = foreach ($k in $En.Table.Keys) {
            if ((Get-Placeholders $En.Table[$k]) -ne (Get-Placeholders $Pl.Table[$k])) { $k }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'formats every message without an error' {
        $bad = foreach ($t in @($En.Table, $Pl.Table)) {
            foreach ($k in $t.Keys) { try { $null = $t[$k] -f 1, 2, 3, 4, 5, 6, 7, 8, 9 } catch { $k } }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'defines every literal key used in the code' {
        $missing = foreach ($f in Get-ChildItem $ModuleRoot -Recurse -Filter '*.ps1') {
            $text = Get-Content $f.FullName -Raw
            foreach ($m in [regex]::Matches($text, "\bT '([^']+)'|Key = '([^']+)'")) {
                $k = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })
                if ($k -in 'key', 'plan.action.<code>') { continue }   # examples in comments
                if (-not $En.Table.ContainsKey($k)) { "$k ($($f.Name))" }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'defines the keys built dynamically in the code (<Prefix>)' -ForEach @(
        @{ Prefix = 'plan.action.';   Values = 'install', 'update', 'skip', 'current', 'missing' }
        @{ Prefix = 'inv.status.';    Values = 'Blocked', 'Active', 'NoUpdater', 'NotDetected' }
        @{ Prefix = 'seal.type.';     Values = 'Task', 'Service' }
        @{ Prefix = 'winget.action.'; Values = 'update', 'skip' }
    ) {
        foreach ($v in $Values) { $En.Table.ContainsKey("$Prefix$v") | Should -BeTrue -Because "$Prefix$v" }
    }

    It 'contains no Polish text in the module code (messages belong to pl-PL)' {
        $hits = Get-ChildItem $ModuleRoot -Recurse -Filter '*.ps1' | Select-String -Pattern '[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]'
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Inline EN/PL tables of standalone scripts' -ForEach @(
    @{ File = 'Scripts\Start-Menu.ps1' }
    @{ File = 'Scripts\Test-SysprepReadiness.ps1' }
    @{ File = 'Scripts\Set-FSLogixConfig.ps1' }
    @{ File = 'Scripts\Install-Eclipse.ps1' }
    @{ File = 'Scripts\New-BuildMedia.ps1' }
) {
    It '<File>: en and pl have the same keys' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Install $File), [ref]$null, [ref]$null)
        $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Strings' }, $true) | Select-Object -First 1
        $tables = & ([scriptblock]::Create($assign.Right.Extent.Text))
        Compare-Object @($tables['en'].Keys) @($tables['pl'].Keys) | Should -BeNullOrEmpty
    }
}

Describe 'Source files' {
    BeforeAll {
        $script:Sources = @(Get-ChildItem $Install -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
    }

    It 'PowerShell files are UTF-8 with BOM (Windows PowerShell 5.1 reads Polish text correctly)' {
        $bad = foreach ($f in $Sources) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $f.Name }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'PowerShell and CMD files use CRLF line endings' {
        $bad = foreach ($f in @($Sources) + @(Get-ChildItem $Install -Recurse -File -Filter '*.cmd')) {
            if ([IO.File]::ReadAllText($f.FullName) -match '(?<!\r)\n') { $f.Name }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'START.cmd is plain ASCII (no code page switching in cmd)' {
        [IO.File]::ReadAllBytes((Join-Path $Install 'START.cmd')) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
    }

    It 'every PowerShell file parses without errors' {
        $bad = foreach ($f in $Sources) {
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            if ($e.Count) { "$($f.Name): $($e[0].Message)" }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'JSON files are valid' {
        $bad = foreach ($f in Get-ChildItem $Install -Recurse -File -Filter '*.json') {
            try { $null = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $f.Name }
        }
        $bad | Should -BeNullOrEmpty
    }
}
