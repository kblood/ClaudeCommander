@echo off
if "%1"=="" goto usage
ccsum %1
goto done
:usage
echo Usage: CRC file
:done
