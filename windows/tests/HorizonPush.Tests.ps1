# Invoke-HorizonPushImage.ps1: lookups, push spec and the REST flow pieces (no Connection Server needed).

BeforeAll {
    $script:Install = (Resolve-Path (Join-Path $PSScriptRoot '..\install')).Path
    $script:Push = Join-Path $Install 'Scripts\Invoke-HorizonPushImage.ps1'
    # dot-sourcing loads the functions only (the main part is skipped)
    . $Push -Language en
}

Describe 'Split-HzUser' {
    It '<Name> -> <Domain> / <User>' -ForEach @(
        @{ Name = 'UNI\hzadmin';           Domain = 'UNI';  User = 'hzadmin' }
        @{ Name = 'hzadmin@corp.example';  Domain = 'corp'; User = 'hzadmin' }
    ) {
        $r = Split-HzUser $Name
        $r.Domain | Should -Be $Domain
        $r.User | Should -Be $User
    }
    It 'rejects a name without a domain' { { Split-HzUser 'hzadmin' } | Should -Throw }
}

Describe 'Find-HzVCenter' {
    It 'matches the vCenter by name' {
        $vcs = @([pscustomobject]@{ id = 'vc-1'; name = 'https://vc01.uni.local:443/sdk' }, [pscustomobject]@{ id = 'vc-2'; name = 'https://vc02.uni.local/sdk' })
        (Find-HzVCenter -VCenters $vcs -Name 'vc02.uni.local').id | Should -Be 'vc-2'
    }
    It 'names the registered vCenters when not found' {
        { Find-HzVCenter -VCenters @([pscustomobject]@{ id = 'vc-1'; name = 'vc01' }) -Name 'vc09' } | Should -Throw '*vc01*'
    }
}

Describe 'Select-HzSnapshot' {
    BeforeAll {
        $script:Snaps = @(
            [pscustomobject]@{ id = 's1'; name = 'pre-generalize 2026-09-01'; created_timestamp = 1000 }
            [pscustomobject]@{ id = 's2'; name = 'Gold 2026-09-02'; created_timestamp = 2000 }
            [pscustomobject]@{ id = 's3'; name = 'Gold 2026-10-01'; created_timestamp = 3000 }
            [pscustomobject]@{ id = 's4'; name = 'manual test'; created_timestamp = 4000 }
        )
    }
    It 'takes the newest Gold snapshot by default' { (Select-HzSnapshot -Snapshots $Snaps -Name '' -VmName 'W11').id | Should -Be 's3' }
    It 'takes the named snapshot' { (Select-HzSnapshot -Snapshots $Snaps -Name 'manual test' -VmName 'W11').id | Should -Be 's4' }
    It 'works without created_timestamp (list order)' {
        $s = @([pscustomobject]@{ id = 'a'; name = 'Gold 1' }, [pscustomobject]@{ id = 'b'; name = 'Gold 2' })
        (Select-HzSnapshot -Snapshots $s -Name '' -VmName 'W11').id | Should -Be 'b'
    }
    It 'lists the snapshots when none matches' {
        { Select-HzSnapshot -Snapshots $Snaps -Name 'missing' -VmName 'W11' } | Should -Throw '*Gold 2026-10-01*'
    }
}

Describe 'New-PushImageSpec' {
    It 'has the required fields and keeps the pool vTPM setting' {
        $s = New-PushImageSpec -ParentVmId 'vm-1' -SnapshotId 'snap-3' -Logoff 'WAIT_FOR_LOGOFF' -Start ([datetime]::MinValue) -Vtpm $true
        $s.parent_vm_id | Should -Be 'vm-1'
        $s.snapshot_id | Should -Be 'snap-3'
        $s.logoff_policy | Should -Be 'WAIT_FOR_LOGOFF'
        $s.add_virtual_tpm | Should -BeTrue
        $s.stop_on_first_error | Should -BeTrue
        $s.Contains('start_time') | Should -BeFalse   # immediately
    }
    It 'sends a future start time as Unix milliseconds' {
        $at = (Get-Date).AddDays(1)
        $s = New-PushImageSpec -ParentVmId 'vm-1' -SnapshotId 's' -Logoff 'FORCE_LOGOFF' -Start $at -Vtpm $false
        $s.start_time | Should -Be ([DateTimeOffset]$at.ToUniversalTime()).ToUnixTimeMilliseconds()
    }
    It 'serializes to the API names' {
        $json = New-PushImageSpec -ParentVmId 'v' -SnapshotId 's' -Logoff 'WAIT_FOR_LOGOFF' -Start ([datetime]::MinValue) -Vtpm $false | ConvertTo-Json -Compress
        $json | Should -Match '"parent_vm_id":"v".*"snapshot_id":"s".*"logoff_policy":"WAIT_FOR_LOGOFF"'
    }
}

Describe 'Pool details' {
    It 'reads the pool vTPM setting' {
        Get-HzPoolVtpm ([pscustomobject]@{ provisioning_settings = [pscustomobject]@{ add_virtual_tpm = $true } }) | Should -BeTrue
        Get-HzPoolVtpm ([pscustomobject]@{ name = 'x' }) | Should -BeFalse
    }
    It 'formats the image state, also when fields are missing' {
        $d = [pscustomobject]@{ provisioning_status_data = [pscustomobject]@{
                instant_clone_current_image_state = 'READY'; instant_clone_pending_image_state = 'PUBLISHING'; instant_clone_pending_image_progress = 40 } }
        $s = Format-HzPoolState $d
        $s.Current | Should -Be 'READY'
        $s.Pending | Should -Be 'PUBLISHING'
        $s.Progress | Should -Be '40%'
        (Format-HzPoolState ([pscustomobject]@{ name = 'x' })).Pending | Should -Be '-'
    }
}

Describe 'Invoke-HzApi request' {
    It 'adds the bearer token and JSON body' {
        Mock Invoke-RestMethod { [pscustomobject]@{ Uri = $Uri; Method = $Method; Headers = $Headers; Body = $Body } }
        $script:HzBase = 'https://cs01/rest'; $script:HzToken = 'tok'
        $r = Invoke-HzApi -Method POST -Path '/inventory/v2/desktop-pools/p1/action/schedule-push-image' -Body @{ snapshot_id = 's' }
        $r.Uri | Should -Be 'https://cs01/rest/inventory/v2/desktop-pools/p1/action/schedule-push-image'
        $r.Headers.Authorization | Should -Be 'Bearer tok'
        $r.Body | Should -Be '{"snapshot_id":"s"}'
    }
}

Describe 'Invoke-HorizonPushImage.ps1 run' {
    It 'stops with exit code 2 without vcenter.json' {
        $ErrorActionPreference = 'Continue'
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $Push -Action Status -InstallDir (Join-Path $TestDrive 'none') -Language en 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
    It 'the example config has a Horizon section with pools' {
        $c = Get-Content (Join-Path $Install 'vcenter.example.json') -Raw | ConvertFrom-Json
        $c.Horizon.Server | Should -Not -BeNullOrEmpty
        @($c.Horizon.Pools).Count | Should -BeGreaterThan 0
        $c.Horizon.LogoffPolicy | Should -BeIn @('WAIT_FOR_LOGOFF', 'FORCE_LOGOFF')
    }
}
