@echo off
title Linkus Wahlversuche Dashboard
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
pause
