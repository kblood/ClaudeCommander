@echo off
rem  cc.cmd -- launcher that makes Claude Commander "cd on exit": when you quit,
rem  the shell is left in the directory of cc's active panel. A Windows program
rem  can't change its parent's current directory, so cc.exe writes the path to
rem  %CC_CWD_FILE% and this wrapper cd's there afterwards.
setlocal
set "CC_CWD_FILE=%TEMP%\cc_cwd_%RANDOM%%RANDOM%.txt"
"%~dp0cc.exe" %*
set "_ccdir="
if exist "%CC_CWD_FILE%" (
    set /p _ccdir=<"%CC_CWD_FILE%"
    del "%CC_CWD_FILE%" >nul 2>&1
)
endlocal & if not "%_ccdir%"=="" cd /d "%_ccdir%"
