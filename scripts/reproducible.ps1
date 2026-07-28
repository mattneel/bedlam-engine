# Verify the package is byte-identical across two cold builds.
#
# M0 criterion 10's first quarter. A package that differs run to run cannot be diffed, so
# "did this release change" stops having a cheap answer, and §14.3 identifies a build by
# its schema fingerprint — which requires one build per commit.
#
# **Both builds start from a cleared cache**, because reusing the cache proves only that
# Zig cached the artifact. The interesting question is whether the compiler and linker
# produce the same bytes twice, and only a cold build asks it.
#
# `SOURCE_DATE_EPOCH` is required, not optional. Without it the PE header's TimeDateStamp
# is the wall clock: measured on this repo, two cold builds 30 seconds apart differed in
# exactly two bytes out of 2,586,112 — the COFF timestamp and its copy in the debug
# directory — with even the RSDS debug GUID identical. Everything else about Zig's output
# is already reproducible; that one field is not, and the reproducible-builds convention
# is to pin it from the environment rather than to rewrite the binary afterwards.

param(
    [string]$Epoch = "1000000000"
)

# Continue, not Stop: anyzig writes progress to stderr and PowerShell turns native stderr
# into a terminating error under Stop, which fails the script on output that is not an error.
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "bedlam-repro"

# Hashed via .NET rather than Get-FileHash: this repo is driven from a PowerShell host
# where that cmdlet is absent, and a missing cmdlet under ErrorActionPreference=Continue
# yields an EMPTY string — which compares equal to another empty string and reports a pass.
# A verification script that fails open is worse than none.
function Sha256($path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Build($prefix) {
    if (Test-Path $prefix) { Remove-Item -Recurse -Force $prefix }
    if (Test-Path (Join-Path $repo ".zig-cache")) {
        Remove-Item -Recurse -Force (Join-Path $repo ".zig-cache")
    }
    $env:SOURCE_DATE_EPOCH = $Epoch
    zig build package -p $prefix 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "package build failed" -ForegroundColor Red; exit 1 }
}

$a = Join-Path $scratch "a"
$b = Join-Path $scratch "b"

Write-Host "cold build 1 (SOURCE_DATE_EPOCH=$Epoch)" -ForegroundColor Cyan
Build $a
Write-Host "cold build 2 (SOURCE_DATE_EPOCH=$Epoch)" -ForegroundColor Cyan
Build $b

$ha = Sha256 (Get-ChildItem "$a/package/*.tar")[0].FullName
$hb = Sha256 (Get-ChildItem "$b/package/*.tar")[0].FullName

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

# The equality above is worthless if the packager ignores its inputs, so change one and
# require the output to move. A builder that emitted a constant would pass every check
# written so far.
Write-Host ""
Write-Host "control: a different epoch must produce a different package" -ForegroundColor Cyan
$c = Join-Path $scratch "c"
$Epoch = "1500000000"
Build $c
$hc = Sha256 (Get-ChildItem "$c/package/*.tar")[0].FullName
Write-Host "  build 3  $hc"

if ($hc -eq $ha) {
    Write-Host "the epoch is being ignored, so the check above proves nothing" -ForegroundColor Red
    exit 1
}

Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "package is reproducible" -ForegroundColor Green
