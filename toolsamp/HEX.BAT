@echo off
if "%1"=="" goto usage
cchex %1
goto done
:usage
echo Usage: HEX file
:done
