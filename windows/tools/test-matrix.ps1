# Runs the engine over every preset and every option combination; prints one line per run.
# Usage: powershell -ExecutionPolicy Bypass -File tools\test-matrix.ps1 -Source file.mp3 [-Exe path] [-Extras dir]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Exe = "",
    [string]$Extras = "",
    [string]$Work = "$env:TEMP\openphonic-matrix"
)
# $PSScriptRoot is not available in parameter defaults on Windows PowerShell 5.1
if (-not $Exe) {
    $rid = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
    $Exe = Join-Path (Split-Path $PSScriptRoot -Parent) "dist\$rid\OpenPhonic.exe"
}
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory $Work | Out-Null
$fail = 0

function Run([string]$name, [string]$opts) {
    $log = "$Work\$name.txt"
    $p = Start-Process -FilePath $Exe -ArgumentList "--process `"$Source`" --out `"$Work\$name`" $opts" `
        -Wait -NoNewWindow -PassThru -RedirectStandardOutput $log
    $out = Get-Content $log -Encoding UTF8
    $err = $out | Where-Object { $_ -like 'ERRORE*' }
    if ($p.ExitCode -ne 0 -or $err) {
        Write-Host "FAIL  $name  $err"
        $script:fail = 1
    } else {
        $after = ($out | Where-Object { $_ -like 'DOPO*' }) -replace '^DOPO\s+', ''
        $time = ($out | Where-Object { $_ -like 'TEMPO*' })
        Write-Host ("ok    {0,-28} {1}  {2}" -f $name, $after, $time)
    }
}

foreach ($p in 'podcast', 'youtube', 'broadcast', 'audiobook', 'rescue', 'music') { Run "preset-$p" "--preset $p" }
foreach ($m in 'ai', 'rnnoise', 'classic') {
    foreach ($a in 'auto', 'low', 'medium', 'high', 'max') { Run "denoise-$m-$a" "--denoise $m --amount $a" }
}
foreach ($c in 'auto', 'soft', 'medium', 'hard', 'off') { Run "compressor-$c" "--compressor $c" }
$extra = ""
if ($Extras -and (Test-Path "$Extras\intro.wav")) { $extra += " --intro `"$Extras\intro.wav`" --outro `"$Extras\intro.wav`"" }
if ($Extras -and (Test-Path "$Extras\cover.png")) { $extra += " --cover `"$Extras\cover.png`"" }
Run "all-options" "--all$extra"
exit $fail
