# Builds strongroom_ffi.dll for Windows and stages it under apps/windows/native/<rid>/.
#   pwsh apps/windows/scripts/build-native.ps1 [-Target x86_64-pc-windows-msvc] [-BuildProfile release]
param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [string]$BuildProfile = "release"
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
    $cargoArgs = [System.Collections.Generic.List[string]]::new()
    $cargoArgs.AddRange([string[]]@("build", "-p", "strongroom-ffi", "--lib", "--target", $Target))
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
