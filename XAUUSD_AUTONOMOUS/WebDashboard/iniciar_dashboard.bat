@echo off
rem Doble clic para arrancar el dashboard web en este PC (http://127.0.0.1:8080).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0iniciar_dashboard.ps1" %*
pause
