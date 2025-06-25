@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File ".\restart.ps1"
