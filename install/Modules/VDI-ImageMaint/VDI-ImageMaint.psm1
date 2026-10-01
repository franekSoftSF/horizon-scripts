# VDI-ImageMaint module: loads Private\*.ps1 (sorted by name: 00-Strings, 01-Config first) and Public\*.ps1.
# Top-level variables of these files become module-scope variables.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot

foreach ($f in @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object Name)) { . $f.FullName }
foreach ($f in @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object Name)) { . $f.FullName }

# Default language until Invoke-VdiImageMaint applies -Language
Initialize-Strings -Language 'auto'

Export-ModuleMember -Function 'Invoke-VdiImageMaint'
