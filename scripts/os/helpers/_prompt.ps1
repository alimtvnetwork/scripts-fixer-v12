<#
.SYNOPSIS
    Shared interactive prompt helpers used by --ask flows on Windows.
    Plain Read-Host based; no extra dependencies. Mirrors helpers/_prompt.sh
    on the Unix side.
#>

function Read-PromptString {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Required,
        [string]$Default
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        Write-Host "  ? $Prompt$suffix : " -ForegroundColor Cyan -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($Default)  { return $Default }
            if (-not $Required) { return "" }
            Write-Host "    (required)" -ForegroundColor Yellow
            continue
        }
        return $val
    }
}

function Read-PromptSecret {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Required
    )
    while ($true) {
        Write-Host "  ? $Prompt (hidden) : " -ForegroundColor Cyan -NoNewline
        $secure = Read-Host -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $val = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ([string]::IsNullOrEmpty($val) -and $Required) {
            Write-Host "    (required)" -ForegroundColor Yellow
            continue
        }
        return $val
    }
}

function Confirm-Prompt {
    param([Parameter(Mandatory)][string]$Prompt, [switch]$DefaultYes)
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    Write-Host "  ? $Prompt $hint : " -ForegroundColor Cyan -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return [bool]$DefaultYes }
    return ($val -match '^(?i)y')
}
