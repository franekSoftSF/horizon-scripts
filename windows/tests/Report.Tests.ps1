# Cycle journal (cycle.json) and the HTML report.

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    Import-Module (Join-Path $Install 'Modules\VDI-ImageMaint\VDI-ImageMaint.psd1') -Force
    Mock -ModuleName VDI-ImageMaint Write-Log { }
    InModuleScope VDI-ImageMaint { Initialize-Strings -Language 'en' }
}

AfterAll { Remove-Module VDI-ImageMaint -Force -ErrorAction SilentlyContinue }

Describe 'Get-AppDiff' {
    It 'finds new, updated and removed applications' {
        InModuleScope VDI-ImageMaint {
            $before = @([pscustomobject]@{ Name = 'A'; Version = '1' }, [pscustomobject]@{ Name = 'B'; Version = '1' }, [pscustomobject]@{ Name = 'C'; Version = '1' })
            $after  = @([pscustomobject]@{ Name = 'A'; Version = '1' }, [pscustomobject]@{ Name = 'B'; Version = '2' }, [pscustomobject]@{ Name = 'D'; Version = '5' })
            $d = Get-AppDiff -Before $before -After $after
            ($d | ForEach-Object { "$($_.App):$($_.Kind)" }) -join ',' | Should -Be 'B:updated,C:removed,D:new'
        }
    }
}

Describe 'Cycle journal' {
    BeforeEach {
        InModuleScope VDI-ImageMaint -Parameters @{ Dir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) } {
            $script:CycleFile = Join-Path $Dir 'cycle.json'
            $script:ReportDir = Join-Path $Dir 'Reports'
            $script:Cycle = $null; $script:CycleRun = $null
        }
        Mock -ModuleName VDI-ImageMaint Get-InstalledApps { [pscustomobject]@{ Name = 'Microsoft Teams'; Version = '25.1' } }
    }

    It 'ignores read-only modes' {
        InModuleScope VDI-ImageMaint {
            Start-CycleRun -RunMode 'Status'
            Test-Path $script:CycleFile | Should -BeFalse
        }
    }

    It 'keeps runs of separate processes in one cycle and closes it with a report' {
        Mock -ModuleName VDI-ImageMaint Get-ReportFacts {
            [pscustomobject]@{ Release = (& (Get-Module VDI-ImageMaint) { Get-WindowsRelease -Build 26100 }); Apps = @([pscustomobject]@{ Name = 'Microsoft Teams'; Version = '25.2' })
                AgentVersion = '8.16.0.1'; Infra = @(); Sealed = $true; SealCreated = '2026-10-02'; Services = @(); ActiveTasks = 0
                PoliciesSet = 5; PoliciesAll = 5; Pending = @() }
        }
        InModuleScope VDI-ImageMaint {
            # run 1: Update (e.g. before a reboot)
            Start-CycleRun -RunMode 'Update'
            Add-CycleEvent 'STEP' 'Windows Update'
            Add-CycleItem -Kind Updates -Item @{ Title = 'KB5124010'; Result = 'Succeeded' }
            Add-CycleItem -Kind Packages -Item @{ Id = 'FSLogix'; Name = 'FSLogix'; From = '25.1'; To = '26.8'; Result = 'ok' }
            [void](Stop-CycleRun -ExitCode 0)
            # run 2: a new process (state in memory is gone), e.g. the SYSTEM child
            $script:Cycle = $null
            Start-CycleRun -RunMode 'Unlock'
            Add-CycleEvent 'WARN' 'service <WaaSMedicSvc> & co'
            [void](Stop-CycleRun -ExitCode 0)
            # run 3: Seal closes the cycle
            Start-CycleRun -RunMode 'Seal'
            Add-CycleEvent 'ERR' 'something failed'
            $path = Stop-CycleRun -ExitCode 0 -Close

            $c = Read-Cycle
            @($c.Runs).Count | Should -Be 3
            (@($c.Runs) | ForEach-Object Mode) -join ',' | Should -Be 'Update,Unlock,Seal'
            $c.Closed | Should -Not -BeNullOrEmpty
            Test-Path $path | Should -BeTrue
            Test-Path (Join-Path $script:ReportDir "cycle_$($c.Id).json") | Should -BeTrue

            $html = Get-Content $path -Raw -Encoding UTF8
            $html | Should -Match '<!DOCTYPE html>'
            $html | Should -Match 'KB5124010'
            $html | Should -Match 'FSLogix'
            $html | Should -Match 'Microsoft Teams</td><td>updated</td><td>25\.1</td><td>25\.2'
            $html | Should -Match '&lt;WaaSMedicSvc&gt; &amp; co'          # messages are HTML-encoded
            $html | Should -Not -Match '<WaaSMedicSvc>'
            $html | Should -Match 'class="badge err"'                    # an ERR makes the cycle red
            $html | Should -Not -Match '<script|https?://(?!www\.w3)'    # self-contained, no external resources

            # the next changing run starts a new cycle
            Start-CycleRun -RunMode 'Update'
            (Read-Cycle).Id | Should -Not -Be $c.Id
            [void](Stop-CycleRun -ExitCode 0)
        }
    }

    It 'survives a missing or broken journal' {
        InModuleScope VDI-ImageMaint {
            $null = New-Item -ItemType Directory -Path (Split-Path $script:CycleFile) -Force
            Set-Content -Path $script:CycleFile -Value '{ broken'
            Read-Cycle | Should -BeNullOrEmpty
            { Start-CycleRun -RunMode 'Packages'; [void](Stop-CycleRun -ExitCode 1) } | Should -Not -Throw
            @((Read-Cycle).Runs)[0].ExitCode | Should -Be 1
        }
    }
}

Describe 'New-CycleReport in Polish' {
    It 'uses the Polish texts' {
        InModuleScope VDI-ImageMaint -Parameters @{ Out = (Join-Path $TestDrive 'pl') } {
            Initialize-Strings -Language 'pl'
            try {
                $c = [pscustomobject]@{ Id = 'x'; Started = '2026-10-02T08:00:00'; Closed = $null; Computer = 'GOLD'; WindowsBefore = '24H2 26100.1'; AppsBefore = @(); Runs = @() }
                $f = [pscustomobject]@{ Release = (& (Get-Module VDI-ImageMaint) { Get-WindowsRelease -Build 26100 }); Apps = @(); AgentVersion = ''; Infra = @(); Sealed = $false
                    SealCreated = ''; Services = @(); ActiveTasks = 2; PoliciesSet = 0; PoliciesAll = 5; Pending = @('CBS') }
                $html = Get-Content (New-CycleReport -Cycle $c -Facts $f -OutDir $Out) -Raw -Encoding UTF8
                $html | Should -Match 'Raport cyklu złotego obrazu'
                $html | Should -Match 'Oczekujący restart: CBS'
                $html | Should -Match 'lang="pl"'
            } finally { Initialize-Strings -Language 'en' }
        }
    }
}
