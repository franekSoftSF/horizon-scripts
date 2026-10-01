@{
    # Invoke-ScriptAnalyzer -Path windows\install -Recurse -Settings windows\PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                        # coloured console output is captured by the transcript on purpose
        'PSAvoidUsingPositionalParameters',             # internal helpers (Get-PV, T, Test-Policy) are called positionally
        'PSUseSingularNouns',                           # Get-InstalledApps, Disable-UpdateTasks ... read naturally in plural
        'PSUseShouldProcessForStateChangingFunctions',  # the tool is not an interactive cmdlet; Unlock reverses Seal
        'PSAvoidOverwritingBuiltInCmdlets',             # Write-Log only exists in PowerShell Core compatibility data
        'PSAvoidUsingEmptyCatchBlock'                   # deliberate: optional cleanup (Stop-Transcript, console encoding)
    )
}
