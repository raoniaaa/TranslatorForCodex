@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0install-windows.ps1"
if errorlevel 1 pause
