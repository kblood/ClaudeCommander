@echo off
if "%1"=="" goto usage
echo File: %1
dir %1
ccsum %1
goto done
:usage
echo Usage: INFO file
:done
