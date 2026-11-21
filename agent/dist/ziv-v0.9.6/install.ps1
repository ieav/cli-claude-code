# Install ziv for the current user (no admin): copies ziv.exe to
# %LOCALAPPDATA%\Programs\ziv and adds it to the user PATH.
# Usage: .\install.ps1 [-Uninstall]
param([switch]$Uninstall)
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:LOCALAPPDATA "Programs\ziv"
if ($Uninstall) {
  if (Test-Path "$dir\ziv.exe") { Remove-Item -Recurse -Force $dir; "removed: $dir" }
  else { "ziv not found at $dir" }
  exit 0
}
$src = Join-Path $PSScriptRoot "ziv-x86_64-windows-gnu.exe"
if (-not (Test-Path $src)) { "missing $src"; exit 1 }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $src "$dir\ziv.exe" -Force
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dir*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
  "note: $dir added to PATH — open a NEW terminal for it to take effect"
}
"installed: $dir\ziv.exe"
"per-project data lands in .ziv\ inside each working directory;"
"global config in %APPDATA%\ziv\"
