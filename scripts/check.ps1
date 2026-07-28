# Everything that can be checked on this machine, before pushing.
#
# This script exists because of a specific, repeated failure: a change passed
# `zig build test` on Windows and aborted on every Linux and macOS CI row. Twice. Both
# times the cause was platform behaviour that Windows tolerates and POSIX does not —
# a zero-length `sendto` whose empty slice carries a dangling pointer, rejected as EFAULT.
#
# All three of these run locally. Using CI to discover them is using a ten-minute feedback
# loop for something a two-minute one would catch.
#
#   1. Windows native      — the one platform backend that is real
#   2. Linux native (WSL2) — POSIX syscall behaviour, a different libc, a different Io path
#   3. Foreign ISAs (qemu) — big-endian and 32-bit, which no shipping target can falsify
#
# Debug AND ReleaseSafe on both native hosts: safety checks change which failures are
# panics and which are silently-wrong values, and CI runs both.

param(
    [switch]$SkipCross,
    [string]$CacheDir = "/tmp/bedlam-wsl-cache"
)

$ErrorActionPreference = "Continue"

$repo = Split-Path -Parent $PSScriptRoot
$drive = $repo.Substring(0, 1).ToLower()
$wslPath = "/mnt/$drive" + $repo.Substring(2).Replace("\", "/")

$failures = @()

# `& $block` runs the block in Step's scope, so a variable from the calling loop is not
# visible inside it. Arguments are passed explicitly for that reason.
function Step($name, $script, $arg) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    & $script $arg
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $name" -ForegroundColor Red
        $script:failures += $name
    }
}

foreach ($mode in @("Debug", "ReleaseSafe")) {
    # The flag is built as a string first. As a bare token, `-Doptimize=$m` reaches zig
    # with the dollar sign intact -- PowerShell does not expand a variable inside a token
    # that begins with a dash. That produced two failures that were not real.
    Step "windows $mode" { param($m) zig build test "-Doptimize=$m" --summary all } $mode
    Step "linux $mode (wsl2)" {
        param($m)
        wsl.exe -e bash -lc "cd '$wslPath' && zig build test -Doptimize=$m --cache-dir '$CacheDir' --summary all"
    } $mode
}

# The web target is a compile-and-run check, not a test suite: the wasm digest must match
# the native one, which is §7's claim on the target where it is hardest to hold.
Step "wasm32 parity" {
    zig build web
    if ($LASTEXITCODE -eq 0) { node tools/web/check.mjs ./zig-out/bin/bedlam_engine.exe }
}

Step "determinism" {
    zig build
    if ($LASTEXITCODE -eq 0) { ./zig-out/bin/bedlam_engine.exe --verify-determinism }
}

if (-not $SkipCross) {
    Step "cross (qemu: aarch64, s390x, arm, mips)" {
        wsl.exe -e bash -lc "cd '$wslPath' && zig build cross --cache-dir '$CacheDir' --summary all"
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "all checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED: $($failures -join ', ')" -ForegroundColor Red
exit 1
