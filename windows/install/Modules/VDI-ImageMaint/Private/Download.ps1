# -Mode Download: freely available packages (Microsoft, VMware) straight into the C:\install folders.
# Every file is checked (Authenticode signer) before it replaces anything; unchanged files (SHA-256) stay as they are.

function Get-DownloadCatalog {
    # C:\install\downloads.json overrides the built-in catalog
    $p = Join-Path $InstallDir 'downloads.json'
    if (-not (Test-Path $p)) { $p = Join-Path $script:ModuleRoot 'Templates\downloads.json' }
    Write-Log (T 'dl.catalog' $p)
    return @(Get-PV (Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json) 'Packages' @())
}

function Resolve-DownloadUrl {
    # Follows redirects (aka.ms, fwlink) to get the real file name; servers that refuse HEAD keep the original URL
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'VDI-ImageMaint'
        $resp = $req.GetResponse()
        try { return $resp.ResponseUri.AbsoluteUri } finally { $resp.Close() }
    } catch { return $Url }
}

function Get-IndexFileUrl {
    # Newest file from a folder listing (e.g. packages.vmware.com) matching the regex
    param([string]$Url, [string]$Pattern)
    $html = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent 'VDI-ImageMaint').Content
    $names = @([regex]::Matches($html, $Pattern) | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($names.Count -eq 0) { throw (T 'dl.indexEmpty' $Url) }
    $best = $names | Sort-Object @{ Expression = { ConvertTo-Version $_ }; Descending = $true } | Select-Object -First 1
    return ($Url.TrimEnd('/') + '/' + $best)
}

function Save-WebFile {
    param([string]$Url, [string]$Path)
    $pp = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower in PS 5.1
    try { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -UserAgent 'VDI-ImageMaint' }
    finally { $ProgressPreference = $pp }
}

function Assert-Signature {
    # Throws when the file is not signed by the expected publisher; '' = no check (MSIX is verified by Windows)
    param([string]$Path, [string]$Signer)
    if (-not $Signer) { Write-Log (T 'dl.noSigCheck' (Split-Path $Path -Leaf)); return }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $subject = $(if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' })
    if ($sig.Status -ne 'Valid' -or $subject -notmatch $Signer) {
        throw (T 'dl.badSig' (Split-Path $Path -Leaf) $sig.Status $subject)
    }
}

function Install-DownloadedFile {
    # Copies $Source to $Folder\$Name unless an identical file is already there; returns 'new' or 'current'
    param([string]$Source, [string]$Folder, [string]$Name, [string]$ReplacePattern = '')
    if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    $dst = Join-Path $Folder $Name
    if ((Test-Path $dst) -and (Get-FileHash $dst -Algorithm SHA256).Hash -eq (Get-FileHash $Source -Algorithm SHA256).Hash) {
        Write-Log (T 'dl.current' (Get-RelativePath $dst)) OK
        return 'current'
    }
    Copy-Item -Path $Source -Destination $dst -Force
    Write-Log (T 'dl.saved' (Get-RelativePath $dst) ('{0:N1}' -f ((Get-Item $dst).Length / 1MB))) OK
    if ($ReplacePattern) {
        foreach ($old in @(Get-ChildItem -Path $Folder -Filter $ReplacePattern -File | Where-Object { $_.Name -ne $Name })) {
            Remove-Item -LiteralPath $old.FullName -Force
            Write-Log (T 'dl.oldRemoved' $old.Name)
        }
    }
    return 'new'
}

function Invoke-Download {
    Write-Log (T 'dl.step') STEP
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ('VDI-ImageMaint_dl_' + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $stat = @{ new = 0; current = 0; failed = 0 }
    try {
        foreach ($d in @(Get-DownloadCatalog)) {
            if (-not [bool](Get-PV $d 'Enabled' $true)) { continue }
            $id = [string](Get-PV $d 'Id' '?')
            Write-Log ("[{0}] {1}" -f $id, (Get-PV $d 'Name' $id)) STEP
            try {
                $kind   = [string](Get-PV $d 'Kind' 'file')
                $signer = [string](Get-PV $d 'Signer' '')
                $url    = [string](Get-PV $d 'Url' '')
                $final  = $(if ($kind -eq 'html-index') { Get-IndexFileUrl -Url $url -Pattern ([string](Get-PV $d 'IndexPattern' '')) } else { Resolve-DownloadUrl $url })
                $name   = [string](Get-PV $d 'FileName' '*')
                if (-not $name -or $name -eq '*') { $name = [Uri]::UnescapeDataString([IO.Path]::GetFileName(([Uri]$final).AbsolutePath)) }
                Write-Log (T 'dl.from' $final)
                $file = Join-Path $tmp $name
                Save-WebFile -Url $final -Path $file
                $target = Join-Path $InstallDir ([string](Get-PV $d 'Target' ''))
                $replace = [string](Get-PV $d 'ReplacePattern' '')

                switch ($kind) {
                    'zip-extract' {
                        $x = Join-Path $tmp "$id-x"
                        Expand-Archive -Path $file -DestinationPath $x -Force
                        foreach ($e in @(Get-PV $d 'Extract' @())) {
                            $hit = Get-ChildItem -Path $x -Recurse -File -Filter ([string]$e.Pattern) | Select-Object -First 1
                            if (-not $hit) { throw (T 'dl.notInZip' $e.Pattern $name) }
                            Assert-Signature -Path $hit.FullName -Signer $signer
                            $stat[(Install-DownloadedFile -Source $hit.FullName -Folder (Join-Path $InstallDir ([string]$e.Target)) -Name $hit.Name)]++
                        }
                    }
                    'zip-keep' {
                        # the archive stays whole (the package platform extracts it) - check the files inside first
                        $x = Join-Path $tmp "$id-x"
                        Expand-Archive -Path $file -DestinationPath $x -Force
                        $signed = @(Get-ChildItem -Path $x -Recurse -File -Filter ([string](Get-PV $d 'SignedFiles' '*.exe')))
                        if ($signed.Count -eq 0) { throw (T 'dl.notInZip' (Get-PV $d 'SignedFiles' '*.exe') $name) }
                        foreach ($s in $signed) { Assert-Signature -Path $s.FullName -Signer $signer }
                        Write-Log (T 'dl.zipChecked' $signed.Count)
                        $stat[(Install-DownloadedFile -Source $file -Folder $target -Name $name -ReplacePattern $replace)]++
                    }
                    default {
                        Assert-Signature -Path $file -Signer $signer
                        $stat[(Install-DownloadedFile -Source $file -Folder $target -Name $name -ReplacePattern $replace)]++
                    }
                }
            } catch {
                Write-Log (T 'dl.failed' $id $_.Exception.Message) WARN
                $stat.failed++
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log (T 'dl.summary') STEP
    Write-Log (T 'dl.counts' $stat.new $stat.current $stat.failed) $(if ($stat.failed) { 'WARN' } else { 'OK' })
    Write-Log (T 'dl.manual')
    foreach ($k in 'dl.manual.osot', 'dl.manual.agents', 'dl.manual.patches', 'dl.manual.nvidia') { Write-Log ('  - ' + (T $k)) }
    if ($stat.failed) { throw (T 'dl.someFailed' $stat.failed) }
}
