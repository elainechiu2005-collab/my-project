@echo off
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_sumo_yolo.ps1" %*
