$dirs = @{
  MISE_DATA_DIR = Join-Path $env:RUNNER_TEMP 'mise data dir'
  MISE_CACHE_DIR = Join-Path $env:RUNNER_TEMP 'mise cache dir'
  MISE_CONFIG_DIR = Join-Path $env:RUNNER_TEMP 'mise config dir'
  MISE_STATE_DIR = Join-Path $env:RUNNER_TEMP 'mise state dir'
  MISE_TMP_DIR = Join-Path $env:RUNNER_TEMP 'mise tmp dir'
}

foreach ($item in $dirs.GetEnumerator()) {
  New-Item -ItemType Directory -Force -Path $item.Value | Out-Null
  "$($item.Key)=$($item.Value)" >> $env:GITHUB_ENV
}
