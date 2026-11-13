# Installs OpenPhonic for the current user (no administrator rights needed):
# copies the app to %LOCALAPPDATA%\Programs\OpenPhonic, adds Start menu and desktop shortcuts,
# and registers it in "App installate" so it can be removed from Windows settings.
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'app'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\OpenPhonic'
$exe = Join-Path $dest 'OpenPhonic.exe'

Get-Process OpenPhonic -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item "$src\*" $dest -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'disinstalla.ps1') $dest -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'OpenPhonic.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $dest
    $lnk.IconLocation = "$exe,0"
    $lnk.Description = 'Post-produzione audio automatica'
    $lnk.Save()
}

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OpenPhonic'
New-Item $key -Force | Out-Null
$version = (Get-Item $exe).VersionInfo.ProductVersion
$size = [int]((Get-ChildItem $dest -Recurse | Measure-Object Length -Sum).Sum / 1KB)
$values = @{
    DisplayName = 'OpenPhonic'; DisplayVersion = $version; Publisher = 'Giuseppe Lupo'
    DisplayIcon = "$exe,0"; InstallLocation = $dest
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dest\disinstalla.ps1`""
}
foreach ($k in $values.Keys) { Set-ItemProperty $key $k $values[$k] }
Set-ItemProperty $key EstimatedSize $size -Type DWord
Set-ItemProperty $key NoModify 1 -Type DWord
Set-ItemProperty $key NoRepair 1 -Type DWord

Write-Host "OpenPhonic $version installato in $dest"
if (-not $env:OPENPHONIC_NO_LAUNCH) { Start-Process $exe }
