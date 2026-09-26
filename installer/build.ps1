# Builds Lenny-Setup-<version>.exe into target\: release desktop app, broker service, both camera DLLs (x64 + x86),
# then NSIS. Needs: rustup target add i686-pc-windows-msvc; NSIS (winget install NSIS.NSIS).
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

cargo build --release -p lenny_desktop -p lenny_vcam -p lenny_vcam_com
if ($LASTEXITCODE) { exit $LASTEXITCODE }
cargo build --release -p lenny_vcam_com --target i686-pc-windows-msvc
if ($LASTEXITCODE) { exit $LASTEXITCODE }

$version = (Select-String -Path desktop\Cargo.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
& "${env:ProgramFiles(x86)}\NSIS\makensis.exe" /V2 "/DVERSION=$version" installer\lenny.nsi
exit $LASTEXITCODE
