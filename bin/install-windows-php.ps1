<#
.SYNOPSIS
Downloads and sets up a specified PHP version on Windows directly into a custom path.

.PARAMETER Version
Full PHP version (e.g., 8.4.15).

.PARAMETER Arch
x64 or x86 (default: x64).

.PARAMETER ThreadSafe
Download Thread Safe build (default: $False).

.PARAMETER Timezone
date.timezone string for php.ini (default: 'UTC').

.PARAMETER CustomPath
Directory to install PHP directly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+(\.\d+)?(\.\d+)?((alpha|beta|RC)\d*)?$')]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [ValidateSet("x64", "x86")]
    [string]$Arch = "x64",

    [Parameter(Mandatory = $false)]
    [bool]$ThreadSafe = $False,

    [Parameter(Mandatory = $false)]
    [string]$Timezone = 'UTC',

    [Parameter(Mandatory = $true)]
    [string]$CustomPath
)

Function Get-File {
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$FallbackUrl,
        [string]$OutFile = '',
        [int]$Retries = 3,
        [int]$TimeoutSec = 0
    )
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if($OutFile) { Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop; return }
            else { return Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop }
        } catch {
            if ($i -eq ($Retries - 1) -and $FallbackUrl) {
                if($OutFile) { Invoke-WebRequest -Uri $FallbackUrl -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop; return }
                else { return Invoke-WebRequest -Uri $FallbackUrl -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop }
            } elseif ($i -eq ($Retries - 1)) { throw "Failed to download: $Url" }
        }
    }
}

Function Get-VSVersion {
    param([string]$Version)
    $map = @{
        '5.2'='VC6'; '5.3'='VC9'; '5.4'='VC9'; '5.5'='VC11'; '5.6'='VC11';
        '7.0'='VC14'; '7.1'='VC14'; '7.2'='VC15'; '7.3'='VC15'; '7.4'='vc15';
        '8.0'='vs16'; '8.1'='vs16'; '8.2'='vs16'; '8.3'='vs16';
        '8.4'='vs17'; '8.5'='vs17'
    }
    if ($map.ContainsKey($Version)) { return $map[$Version] }
    throw "Unsupported PHP version: $Version"
}

Function Get-ReleaseType { param([string]$Version); if ($Version -match "[a-zA-Z]") { return "qa" } else { return "releases" } }

Function Get-PhpFromUrl {
    param([string]$Version, [string]$Semver, [string]$Arch, [bool]$ThreadSafe, [string]$OutFile)
    $vs = Get-VSVersion $Version
    $ts = if ($ThreadSafe) { "ts" } else { "nts" }
    $zipName = if ($ThreadSafe) { "php-$Semver-Win32-$vs-$Arch.zip" } else { "php-$Semver-$ts-Win32-$vs-$Arch.zip" }
    $type = Get-ReleaseType $Semver
    $base = "https://downloads.php.net/~windows/$type"
    try { Get-File -Url "$base/$zipName" -OutFile $OutFile } catch { Get-File -Url "$base/archives/$zipName" -OutFile $OutFile }
}

$tempFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.zip')

try {
    if (-not (Test-Path $CustomPath)) { New-Item -ItemType Directory -Path $CustomPath | Out-Null }

    $Semver = $Version
    $installDirectory = [Environment]::ExpandEnvironmentVariables($CustomPath)

    Write-Host "Downloading PHP $Semver ($Arch, $(if($ThreadSafe){'ts'}else{'nts'})) -> $installDirectory"
    Get-PhpFromUrl $Semver $Semver $Arch $ThreadSafe $tempFile

    Expand-Archive -Path $tempFile -DestinationPath $installDirectory -Force -ErrorAction Stop

    $phpIniProd = Join-Path $installDirectory "php.ini-production"
    if(-not(Test-Path $phpIniProd)) { $phpIniProd = Join-Path $installDirectory "php.ini-recommended" }
    $phpIni = Join-Path $installDirectory "php.ini"
    if (Test-Path $phpIniProd) {
        Copy-Item $phpIniProd $phpIni -Force
        $extDir = Join-Path $installDirectory "ext"
        (Get-Content $phpIni) -replace '^extension_dir = "./"', "extension_dir = `"$extDir`"" | Set-Content $phpIni
        (Get-Content $phpIni) -replace ';\s?extension_dir = "ext"', "extension_dir = `"$extDir`"" | Set-Content $phpIni
        (Get-Content $phpIni) -replace ';\s?date.timezone =', "date.timezone = `"$Timezone`"" | Set-Content $phpIni
    }

    Function Set-PathEntryFirst {
        param([ValidateSet('User','Machine')][string]$Target,[string]$Entry)
        $entryNorm = ($Entry.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant()
        $existing = [Environment]::GetEnvironmentVariable('Path', $Target) -split ';' | Where-Object { ($_ -and ($_.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant() -ne $entryNorm) }
        [Environment]::SetEnvironmentVariable('Path', ($Entry + ';' + ($existing -join ';')), $Target)
        $env:Path = ($Entry + ';' + ($env:Path -split ';' | Where-Object { ($_ -and ($_.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant() -ne $entryNorm) } -join ';'))
    }

    $pathTarget = 'User'
    Set-PathEntryFirst -Target $pathTarget -Entry $installDirectory

    Write-Host ""
    Write-Host "Installed PHP $Semver directly to $installDirectory"
    Write-Host "Added to PATH. Restart your shells or IDEs to apply."
    Write-Host "Run 'php -v' to verify."
} catch {
    Write-Error $_
    Exit 1
} finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}
