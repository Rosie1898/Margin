@echo off
setlocal
cd /d "%~dp0"
if exist "dist\win-unpacked\Margin.exe" (
  start "" "dist\win-unpacked\Margin.exe"
  exit /b 0
)
echo Packaged application not found. Build with npm install then npm run build.
pause
