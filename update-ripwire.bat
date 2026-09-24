@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0update-ripwire.ps1" %*
exit /b %errorlevel%
