# Removes OpenPhonic: program folder, shortcuts and the "App installate" entry.
# Productions history and Whisper models in %LOCALAPPDATA%\OpenPhonic are kept unless -Tutto is given.
param([switch]$Tutto)
Get-Process OpenPhonic -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    Remove-Item (Join-Path $dir 'OpenPhonic.lnk') -ErrorAction SilentlyContinue
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OpenPhonic' -Recurse -ErrorAction SilentlyContinue
if ($Tutto) { Remove-Item (Join-Path $env:LOCALAPPDATA 'OpenPhonic') -Recurse -Force -ErrorAction SilentlyContinue }
# the script lives inside the folder it deletes: finish from a detached shell
$dest = Join-Path $env:LOCALAPPDATA 'Programs\OpenPhonic'
Start-Process cmd.exe "/c timeout /t 2 >nul & rmdir /s /q `"$dest`"" -WindowStyle Hidden
Write-Host 'OpenPhonic disinstallato.'
