# Generates the C# bindings from the frozen UDL with uniffi-bindgen-cs.
# Install once:
#   cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.11.1+v0.31.0
param(
    [string]$Bindgen = "uniffi-bindgen-cs"
)
$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$udl = Join-Path $repo "crates\strongroom-ffi\src\strongroom.udl"
$config = Join-Path $repo "apps\windows\uniffi.toml"
$out = Join-Path $repo "apps\windows\src\Strongroom.Core\Generated"
New-Item -ItemType Directory -Force $out | Out-Null

& $Bindgen --version
& $Bindgen $udl --config $config --out-dir $out --no-format
if ($LASTEXITCODE -ne 0) { throw "uniffi-bindgen-cs failed ($LASTEXITCODE)" }
$file = Join-Path $out "strongroom.cs"
if (-not (Test-Path $file)) { throw "bindings not generated at $file" }
"generated $file ($((Get-Item $file).Length) bytes)"
