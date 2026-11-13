# Builds OpenPhonic for Windows: fetches ffmpeg / ffprobe, DeepFilterNet and the RNNoise model,
# then publishes a self-contained app to dist\<rid>\.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build.ps1 [-Rid win-x64|win-arm64] [-Zip]
param(
    [string]$Rid = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }),
    [switch]$Zip
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$third = Join-Path $root "third_party\$Rid"
New-Item -ItemType Directory -Force $third | Out-Null

function Fetch($url, $dest) {
    if (-not (Test-Path $dest)) {
        Write-Host "Download $url"
        Invoke-WebRequest -Uri $url -OutFile "$dest.part" -UseBasicParsing
        Move-Item "$dest.part" $dest -Force
    }
}

# ffmpeg 9.0 (BtbN builds, GPL: includes libmp3lame, libopus, libx264)
if (-not (Test-Path "$third\ffmpeg.exe")) {
    $arch = if ($Rid -eq 'win-arm64') { 'winarm64' } else { 'win64' }
    $zipName = "ffmpeg-n9.0-latest-$arch-gpl-9.0.zip"
    $tmp = Join-Path $env:TEMP "openphonic-ffmpeg-$arch"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Fetch "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$zipName" "$tmp\$zipName"
    Expand-Archive "$tmp\$zipName" -DestinationPath "$tmp\x" -Force
    Get-ChildItem "$tmp\x" -Recurse -Include ffmpeg.exe, ffprobe.exe | Copy-Item -Destination $third -Force
    Get-ChildItem "$tmp\x" -Recurse -Filter LICENSE.txt | Select-Object -First 1 | Copy-Item -Destination "$third\ffmpeg-LICENSE.txt" -Force
}

# DeepFilterNet only ships for x64; Windows 11 on ARM runs it through x64 emulation
Fetch "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-x86_64-pc-windows-msvc.exe" "$third\deep-filter.exe"
Fetch "https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn" "$third\std.rnnn"

$out = Join-Path $root "dist\$Rid"
dotnet publish "$root\OpenPhonic\OpenPhonic.csproj" -c Release -r $Rid --self-contained true `
    -p:PublishReadyToRun=true -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish non riuscito" }

if ($Zip) {
    # package: app\ + installer scripts, zipped
    $pkg = Join-Path $root "dist\OpenPhonic-$Rid"
    if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
    New-Item -ItemType Directory -Force "$pkg\app" | Out-Null
    Copy-Item "$out\*" "$pkg\app" -Recurse -Force
    Copy-Item "$PSScriptRoot\installer\*" $pkg -Force
    $z = "$pkg.zip"
    if (Test-Path $z) { Remove-Item $z }
    Compress-Archive -Path "$pkg\*" -DestinationPath $z -CompressionLevel Optimal
    Write-Host ("ZIP: $z  ({0:N0} MB)" -f ((Get-Item $z).Length / 1MB))
}
Write-Host "OK: $out\OpenPhonic.exe"
