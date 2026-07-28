# Run the foreign-architecture gate from a Windows host.
#
# qemu-user is a Linux binary, so `zig build cross` cannot run natively here — but it runs
# in WSL2, which is where the same gate is exercised for fpz and gkz. This is a pre-commit
# check rather than a CI-only one: s390x is the only place several byte-order invariants
# are checked at all, and finding a regression on a runner is finding it late.
#
# The separate cache dir is not incidental. Sharing .zig-cache between the Windows and WSL2
# builds mixes two hosts' absolute paths and compiler binaries into one cache.

param(
    [string]$Step = "cross",
    [string]$CacheDir = "/tmp/bedlam-wsl-cache"
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$drive = $repo.Substring(0, 1).ToLower()
$wslPath = "/mnt/$drive" + $repo.Substring(2).Replace("\", "/")

Write-Host "cross gate: $wslPath (step: $Step)" -ForegroundColor Cyan

wsl.exe -e bash -lc "cd '$wslPath' && zig build $Step --cache-dir '$CacheDir' --summary all"

if ($LASTEXITCODE -ne 0) {
    Write-Host "cross gate FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "cross gate passed" -ForegroundColor Green
