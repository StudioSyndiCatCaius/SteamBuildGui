@echo off
rem Build SteamBuildGui into bin\ (git-ignored).
rem Everything the app creates at runtime also lives next to the exe in bin\:
rem   steambuildgui.json (config), steamcmd\ (one-click install), steam_build\ (app folders, cache)
rem
rem   build.bat         - optimized GUI build (no console window), icon embedded
rem   build.bat debug   - debug build with console for log output
rem   build.bat icon    - regenerate SteamBuildGui.ico from src\icon.odin, then build

cd /d "%~dp0"
if not exist bin mkdir bin

if "%1"=="icon" (
    odin build src -out:bin\SteamBuildGui.exe || exit /b 1
    bin\SteamBuildGui.exe --write-icon SteamBuildGui.ico || exit /b 1
)

if "%1"=="debug" (
    odin build src -out:bin\SteamBuildGui.exe -debug -vet -strict-style -resource:SteamBuildGui.rc
) else (
    odin build src -out:bin\SteamBuildGui.exe -o:speed -subsystem:windows -vet -strict-style -resource:SteamBuildGui.rc
)
if errorlevel 1 exit /b 1
del /q SteamBuildGui.res 2>nul
echo Built bin\SteamBuildGui.exe
