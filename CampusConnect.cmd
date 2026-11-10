@echo off
if exist "%~dp0CampusConnect.exe" (
    start "" "%~dp0CampusConnect.exe"
) else (
    echo Download the complete Windows ZIP from Releases, or build launcher\build.cmd first.
    pause
)
