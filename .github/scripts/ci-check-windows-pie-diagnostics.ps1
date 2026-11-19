$ErrorActionPreference = 'Stop'

$outputFile = Join-Path $env:RUNNER_TEMP 'pie-extension-diagnostics.out'

$previousNativeCommandPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
  & mise use -g "php@$env:PHP_TEST_VERSION" *>&1 | Tee-Object -FilePath $outputFile
  $installExitCode = $LASTEXITCODE
} finally {
  $PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
}

if ($installExitCode -ne 0) {
  Write-Error "Expected PHP install to continue when requested PIE extensions fail, got exit code ${installExitCode}."
}

$output = Get-Content -LiteralPath $outputFile -Raw

function Require-Output {
  param(
    [string] $Pattern,
    [string] $Message
  )

  if ($output -notmatch $Pattern) {
    Write-Error $Message
  }
}

Require-Output 'PIE extension installed: xdebug/xdebug' 'xdebug/xdebug should be reported as installed.'
Require-Output 'PIE extension installed: imagick/imagick' 'imagick/imagick should be reported as installed.'
Require-Output 'One or more PIE extensions failed to install\.' 'The final PIE failure summary should be shown.'
Require-Output 'Failed PIE extension packages: redis/phpredis, verzly/not-a-real-pie-extension\.' 'Only the two failing PIE packages should be listed.'
Require-Output 'PHP installation continued, but the failed PIE extensions were not installed\.' 'The install should continue after PIE extension failures.'
Require-Output 'Check that each package supports your operating system and PHP version, and that each package name is spelled correctly\.' 'The warning should explain how to validate failed package requests.'
Require-Output 'Retry failed PIE extensions with .*mise exec -- pie install redis/phpredis verzly/not-a-real-pie-extension' 'The warning should include a retry command for failed packages.'
Require-Output 'Debug log: .+ \(redis/phpredis\)' 'redis/phpredis should include a debug log path.'
Require-Output 'Debug log: .+ \(verzly/not-a-real-pie-extension\)' 'The nonexistent package should include a debug log path.'

if ($output -match 'Failed PIE extension packages: .*xdebug/xdebug') {
  Write-Error 'xdebug/xdebug must not be listed as failed.'
}

if ($output -match 'Failed PIE extension packages: .*imagick/imagick') {
  Write-Error 'imagick/imagick must not be listed as failed.'
}

if ($output -match 'Debug log: .+ \(xdebug/xdebug\)') {
  Write-Error 'xdebug/xdebug must not include a failure debug log path.'
}

if ($output -match 'Debug log: .+ \(imagick/imagick\)') {
  Write-Error 'imagick/imagick must not include a failure debug log path.'
}

if ($output -match 'PIE extension installation failed') {
  Write-Error 'PIE extension failures should not abort PHP installation.'
}

if ($output -match 'stack traceback') {
  Write-Error 'PIE extension diagnostics must not include a Lua stack traceback.'
}

$logMatches = [regex]::Matches($output, 'Debug log: (?<path>.+?) \((?<package>.+?)\)')

if ($logMatches.Count -ne 2) {
  Write-Error "Expected exactly 2 failed extension debug log paths, got $($logMatches.Count)."
}

foreach ($match in $logMatches) {
  $path = $match.Groups['path'].Value
  $package = $match.Groups['package'].Value

  if (-not (Test-Path -LiteralPath $path)) {
    Write-Error "Expected debug log to exist for ${package}: ${path}"
  }

  $log = Get-Content -LiteralPath $path -Raw

  if ($log -notmatch [regex]::Escape($package)) {
    Write-Error "Expected debug log for ${package} to contain the package name."
  }
}

# GitHub's pwsh wrapper can propagate a stale native command exit code.
$global:LASTEXITCODE = 0
