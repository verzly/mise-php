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

.PARAMETER InstallExtras
Download and install the PHP extras package containing additional extension DLLs.
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
    [string]$CustomPath,

    [Parameter(Mandatory = $false)]
    [switch]$InstallExtras = $false
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
            if ($OutFile) { Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop; return }
            else { return Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop }
        } catch {
            if ($i -eq ($Retries - 1) -and $FallbackUrl) {
                if ($OutFile) { Invoke-WebRequest -Uri $FallbackUrl -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop; return }
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
    $majorMinor = ($Version -split '\.')[0..1] -join '.'
    if ($map.ContainsKey($majorMinor)) { return $map[$majorMinor] }
    throw "Unsupported PHP version: $Version (resolved major.minor: $majorMinor)"
}

Function Get-ReleaseType {
    param([string]$Version)
    if ($Version -match "[a-zA-Z]") { return "qa" } else { return "releases" }
}

Function Get-PhpFromUrl {
    param([string]$Version, [string]$Semver, [string]$Arch, [bool]$ThreadSafe, [string]$OutFile)
    $majorMinor = ($Version -split '\.')[0..1] -join '.'
    $vs = Get-VSVersion $majorMinor
    $ts = if ($ThreadSafe) { "ts" } else { "nts" }
    $zipName = if ($ThreadSafe) { "php-$Semver-Win32-$vs-$Arch.zip" } else { "php-$Semver-$ts-Win32-$vs-$Arch.zip" }

    $candidates = @(
        "https://windows.php.net/downloads/releases/$zipName",
        "https://windows.php.net/downloads/releases/archives/$zipName",
        "https://windows.php.net/downloads/qa/$zipName",
        "https://downloads.php.net/~windows/releases/$zipName",
        "https://downloads.php.net/~windows/releases/archives/$zipName",
        "https://downloads.php.net/~windows/qa/$zipName"
    )

    foreach ($url in $candidates) {
        try {
            Write-Host "Trying: $url"
            Get-File -Url $url -OutFile $OutFile -Retries 1
            Write-Host "Downloaded from: $url"
            return
        } catch {
            continue
        }
    }

    throw "Could not download PHP $Semver - tried all known URLs"
}

Function Get-PhpExtras {
    param([string]$Version, [string]$Semver, [string]$Arch, [string]$OutFile)
    $majorMinor = ($Version -split '\.')[0..1] -join '.'
    $vs = Get-VSVersion $majorMinor
    # Extras are always nts
    $zipName = "php-$Semver-nts-Win32-$vs-$Arch-extras.zip"

    $candidates = @(
        "https://windows.php.net/downloads/releases/$zipName",
        "https://windows.php.net/downloads/releases/archives/$zipName",
        "https://windows.php.net/downloads/qa/$zipName"
    )

    foreach ($url in $candidates) {
        try {
            Write-Host "Trying extras: $url"
            Get-File -Url $url -OutFile $OutFile -Retries 1
            Write-Host "Downloaded extras from: $url"
            return $true
        } catch {
            continue
        }
    }

    return $false
}

$tempFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.zip')

try {
    Set-Location -LiteralPath $env:TEMP
    if (-not (Test-Path $CustomPath)) { New-Item -ItemType Directory -Path $CustomPath | Out-Null }

    $Semver = $Version
    $installDirectory = [Environment]::ExpandEnvironmentVariables($CustomPath)

    Write-Host "Downloading PHP $Semver ($Arch, $(if($ThreadSafe){'ts'}else{'nts'})) -> $installDirectory"
    Get-PhpFromUrl $Semver $Semver $Arch $ThreadSafe $tempFile
    Expand-Archive -Path $tempFile -DestinationPath $installDirectory -Force -ErrorAction Stop

    # Download extras package (additional extension DLLs)
    if ($InstallExtras) {
        Write-Host "Downloading PHP extras package..."
        $tempExtras = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.zip')
        try {
            $found = Get-PhpExtras $Semver $Semver $Arch $tempExtras
            if ($found) {
                Expand-Archive -Path $tempExtras -DestinationPath $installDirectory -Force -ErrorAction Stop
                Write-Host "Extras installed successfully."
            } else {
                Write-Host "Warning: No extras package found for PHP $Semver - skipping."
            }
        } catch {
            Write-Host "Warning: Failed to install extras - $_"
        } finally {
            if (Test-Path $tempExtras) { Remove-Item $tempExtras -Force -ErrorAction SilentlyContinue }
        }
    }

    $extDir = Join-Path $installDirectory "ext"

    # Warn if ext/ directory is missing (incomplete build)
    if (-not (Test-Path $extDir)) {
        Write-Warning "The ext/ directory is missing from this PHP build."
        Write-Warning "PHP $Semver may not have a complete Windows release yet."
        Write-Warning "Consider using a stable release (e.g. php@8.4) instead."
    }

    $phpIniProd = Join-Path $installDirectory "php.ini-production"
    if (-not (Test-Path $phpIniProd)) { $phpIniProd = Join-Path $installDirectory "php.ini-recommended" }
    $phpIni = Join-Path $installDirectory "php.ini"

    if (Test-Path $phpIniProd) {
        Copy-Item $phpIniProd $phpIni -Force

        (Get-Content $phpIni) -replace '^extension_dir = "./"',     "extension_dir = `"$extDir`"" | Set-Content $phpIni
        (Get-Content $phpIni) -replace ';\s?extension_dir = "ext"', "extension_dir = `"$extDir`"" | Set-Content $phpIni
        (Get-Content $phpIni) -replace ';\s?date.timezone =',       "date.timezone = `"$Timezone`"" | Set-Content $phpIni

        if (Test-Path $extDir) {
            $staticExtensions = (& "$installDirectory\php.exe" -m 2>$null) -split "`n" |
                ForEach-Object { $_.Trim().ToLower() }

            # Extensions that require external dependencies not available on Windows by default
            $blacklist = @('pdo_firebird', 'snmp')

            Get-ChildItem -Path $extDir -Filter "php_*.dll" | ForEach-Object {
                $ext = $_.BaseName -replace '^php_', ''

                if ($blacklist -contains $ext.ToLower()) {
                    Write-Host "Skipping $ext - requires external dependencies"
                } elseif ($staticExtensions -contains $ext.ToLower()) {
                    Write-Host "Skipping $ext - already compiled statically"
                } else {
                    (Get-Content $phpIni) -replace "^;extension=$ext", "extension=$ext" | Set-Content $phpIni
                    Write-Host "Enabled $ext"
                }
            }

            $zendExtensions = @('opcache')
            foreach ($ext in $zendExtensions) {
                $dllPath = Join-Path $extDir "php_$ext.dll"
                $isStatic = $staticExtensions -contains $ext.ToLower()
                if (-not $isStatic -and (Test-Path $dllPath)) {
                    (Get-Content $phpIni) -replace "^;zend_extension=$ext", "zend_extension=$ext" | Set-Content $phpIni
                }
            }
        }
    }

    Function Set-PathEntryFirst {
        param([ValidateSet('User','Machine')][string]$Target, [string]$Entry)
        $entryNorm = ($Entry.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant()

        $existingUser = [Environment]::GetEnvironmentVariable('Path', $Target) -split ';' |
            Where-Object { $_ -and ($_.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant() -ne $entryNorm }
        [Environment]::SetEnvironmentVariable('Path', ($Entry + ';' + ($existingUser -join ';')), $Target)

        $existingEnv = $env:Path -split ';' |
            Where-Object { $_ -and ($_.Trim().Trim('"').TrimEnd('\')).ToLowerInvariant() -ne $entryNorm }
        $env:Path = $Entry + ';' + ($existingEnv -join ';')
    }

    Set-PathEntryFirst -Target 'User' -Entry $installDirectory

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
