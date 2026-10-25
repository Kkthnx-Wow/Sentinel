# Syntax check, lint and headless tests for Sentinel. Run from anywhere.
# Needs luac5.1 / lua5.1 (choco install lua51) and luacheck on PATH.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$failed = $false

Write-Host "== syntax"
Get-ChildItem "!Sentinel\Core", "!Sentinel\UI" -Filter *.lua | ForEach-Object {
	luac5.1 -p $_.FullName
	if ($LASTEXITCODE -ne 0) { $failed = $true }
}

Write-Host "== luacheck"
luacheck "!Sentinel" tests --no-cache
if ($LASTEXITCODE -ne 0) { $failed = $true }

Write-Host "== tests"
Get-ChildItem tests -Filter "test_*.lua" | ForEach-Object {
	lua5.1 $_.FullName.Substring($root.Length + 1)
	if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if ($failed) {
	Write-Host "check failed"
	exit 1
}
Write-Host "check passed"
