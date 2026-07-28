# Verify the package is byte-identical across two cold builds.
#
# M0 criterion 10's first quarter. A package that differs run to run cannot be diffed, so
# "did this release change" stops having a cheap answer, and §14.3 identifies a build by its
# schema fingerprint — which requires one build per commit.
#
# **Both builds start from a cleared cache.** Reusing the cache proves only that Zig cached
# the artifact; the question is whether the compiler and linker produce the same bytes
# twice, and only a cold build asks it.
#
# **Release mode, not Debug.** Measured on this repo (docs/UPSTREAM_FINDINGS.md §6):
#
#   | Mode        | Windows PE                  | Linux ELF        |
#   |-------------|-----------------------------|------------------|
#   | Debug       | needs SOURCE_DATE_EPOCH     | NOT reproducible |
#   | ReleaseSafe | reproducible, no env needed | reproducible     |
#
# A release build therefore needs no environment setup at all, and that is the only mode a
# distributable is ever built in. Testing Debug would be testing the mode nobody ships.

param(
    [string]$Optimize = "ReleaseSafe"
)

# Continue, not Stop: anyzig writes progress to stderr and PowerShell turns native stderr
# into a terminating error under Stop, which fails the script on output that is not an error.
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "bedlam-repro"

# Hashed via .NET rather than Get-FileHash: this repo is driven from a PowerShell host where
# that cmdlet is absent, and a missing cmdlet under ErrorActionPreference=Continue yields an
# EMPTY string — which compares equal to another empty string and reports a pass. A
# verification script that fails open is worse than none.
function Sha256($path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Build($prefix, $mode) {
    if (Test-Path $prefix) { Remove-Item -Recurse -Force $prefix }
    if (Test-Path (Join-Path $repo ".zig-cache")) {
        Remove-Item -Recurse -Force (Join-Path $repo ".zig-cache")
    }
    zig build package "-Doptimize=$mode" -p $prefix 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "package build failed ($mode)" -ForegroundColor Red
        exit 1
    }
    return Sha256 (Get-ChildItem "$prefix/package/*.tar")[0].FullName
}

$a = Join-Path $scratch "a"
$b = Join-Path $scratch "b"

Write-Host "cold build 1 ($Optimize)" -ForegroundColor Cyan
$ha = Build $a $Optimize
Write-Host "cold build 2 ($Optimize)" -ForegroundColor Cyan
$hb = Build $b $Optimize

Write-Host ""
Write-Host "  build 1  $ha"
Write-Host "  build 2  $hb"

if ([string]::IsNullOrEmpty($ha)) {
    Write-Host "could not hash the package; refusing to report a pass" -ForegroundColor Red
    exit 1
}
if ($ha -ne $hb) {
    Write-Host "package is NOT reproducible" -ForegroundColor Red
    exit 1
}

# The equality above is worthless if the pipeline ignores its inputs, so change one and
# require the output to move. A packager that emitted a constant would pass every check
# above.
#
# The control is the OPTIMIZE MODE, and it was SOURCE_DATE_EPOCH first. That was wrong in a
# way worth recording: in release mode the timestamp is not taken from the epoch, so the
# control passed trivially and would have certified a pipeline that ignored its inputs.
Write-Host ""
Write-Host "control: a different optimize mode must produce a different package" -ForegroundColor Cyan
$c = Join-Path $scratch "c"
$other = if ($Optimize -eq "ReleaseSmall") { "ReleaseSafe" } else { "ReleaseSmall" }
$hc = Build $c $other
Write-Host "  build 3  $hc  ($other)"

if ($hc -eq $ha) {
    Write-Host "the build inputs are being ignored; the check above proves nothing" -ForegroundColor Red
    exit 1
}

Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "package is reproducible ($Optimize, no environment setup required)" -ForegroundColor Green
