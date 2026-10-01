# Localized messages: en-US is the primary language and the fallback for every key, pl-PL is the second.
# Each area has its own <Area>.psd1 in en-US\ and pl-PL\ - the same keys in both (checked by tests).

$script:Strings       = @{}
$script:UICultureName = 'en-US'

function Resolve-UICulture {
    param([string]$Language = 'auto')
    switch ($Language) {
        'pl'    { return 'pl-PL' }
        'en'    { return 'en-US' }
        default { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pl') { return 'pl-PL' } else { return 'en-US' } }
    }
}

function Initialize-Strings {
    param([string]$Language = 'auto')
    $ui = Resolve-UICulture $Language
    $script:Strings = @{}
    # en-US first, then the selected culture overrides it - a missing translation falls back to English
    foreach ($culture in @('en-US', $ui) | Select-Object -Unique) {
        $dir = Join-Path $script:ModuleRoot $culture
        foreach ($f in @(Get-ChildItem -Path $dir -Filter '*.psd1' -File -ErrorAction SilentlyContinue)) {
            $data = Import-PowerShellDataFile -Path $f.FullName
            foreach ($k in $data.Keys) { $script:Strings[$k] = $data[$k] }
        }
    }
    $script:UICultureName = $ui
}

function T {
    # T 'key' [arg0] [arg1] ... -> localized, formatted text; unknown key -> [key]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(ValueFromRemainingArguments)][object[]]$Arg
    )
    $s = $script:Strings[$Key]
    if ($null -eq $s) { return "[$Key]" }
    if ($Arg -and $Arg.Count) { return ($s -f $Arg) }
    return $s
}
