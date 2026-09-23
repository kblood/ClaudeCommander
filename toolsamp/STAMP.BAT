@echo off
if "%1"=="" goto usage
cctouch %1
goto done
:usage
echo Usage: STAMP file
:done
