@echo off
title ppedv Calltracking - Einrichtung
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installieren.ps1" %*
pause
