@echo off
setlocal
cd /d "%~dp0.."
where cl.exe >nul 2>nul
if not errorlevel 1 goto build
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto missing
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if not defined VSROOT goto missing
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
:build
if not exist launcher\out mkdir launcher\out
cl.exe /nologo /std:c++17 /utf-8 /W4 /EHsc /MT /O2 /DUNICODE /D_UNICODE launcher\launcher.cpp /Folauncher\out\ /Felauncher\out\CampusConnect.exe /link /SUBSYSTEM:WINDOWS shell32.lib user32.lib
exit /b %errorlevel%
:missing
echo Install Visual Studio with the C++ desktop workload to build this launcher.
exit /b 1
