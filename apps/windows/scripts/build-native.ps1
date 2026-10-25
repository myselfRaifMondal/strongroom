# Builds strongroom_ffi.dll for Windows and stages it under apps/windows/native/<rid>/.
#   pwsh apps/windows/scripts/build-native.ps1 [-Target x86_64-pc-windows-msvc] [-BuildProfile release] [-StaticCrt]
#
# -StaticCrt links the MSVC C runtime statically (`-C target-feature=+crt-static`)
# so the DLL does not need the Visual C++ Redistributable (VCRUNTIME140.dll)
# on the user's machine. The installer build uses it. Only the target's flags
# change (CARGO_TARGET_<TRIPLE>_RUSTFLAGS); nothing under crates/ is touched.
param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [string]$BuildProfile = "release",
    [switch]$StaticCrt
)
$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$rid = switch ($Target) {
    "x86_64-pc-windows-msvc" { "win-x64" }
    "aarch64-pc-windows-msvc" { "win-arm64" }
    default { throw "unsupported target $Target" }
}

Push-Location $repo
try {
    if ($StaticCrt) {
        $flagsVar = "CARGO_TARGET_" + ($Target.ToUpperInvariant() -replace '-', '_') + "_RUSTFLAGS"
        $existing = [Environment]::GetEnvironmentVariable($flagsVar)
        $flags = (@($existing, "-C target-feature=+crt-static") | Where-Object { $_ }) -join " "
        [Environment]::SetEnvironmentVariable($flagsVar, $flags)
        "static CRT: $flagsVar=$flags"
    }
    $cargoArgs = [System.Collections.Generic.List[string]]::new()
    # --locked: build exactly the crate versions in Cargo.lock (the ones CI
    # tests and audits); fail instead of resolving new ones.
    $cargoArgs.AddRange([string[]]@("build", "--locked", "-p", "strongroom-ffi", "--lib", "--target", $Target))
    if ($BuildProfile -eq "release") { $cargoArgs.Add("--release") }
    & cargo $cargoArgs.ToArray()
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
    $dir = if ($BuildProfile -eq "release") { "release" } else { "debug" }
    $dll = Join-Path $repo "target\$Target\$dir\strongroom_ffi.dll"
    $dest = Join-Path $repo "apps\windows\native\$rid"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item $dll $dest -Force
    Get-Item (Join-Path $dest "strongroom_ffi.dll") | Format-Table Name, Length, LastWriteTime
} finally {
    Pop-Location
}
