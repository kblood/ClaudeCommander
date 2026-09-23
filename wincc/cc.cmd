@echo off
rem  cc.cmd -- launcher that makes Claude Commander "cd on exit": when you quit,
rem  the shell is left in the directory of cc's active panel. A Windows program
rem  can't change its parent's current directory, so cc.exe writes the path to
rem  %CC_CWD_FILE% and this wrapper cd's there afterwards.
rem  cc.exe writes that file as UTF-8 and "set /p" decodes with the console
rem  codepage, so the read runs under "chcp 65001" and the user's codepage is
rem  restored right after. cmd only picks up a chcp change between top-level
rem  lines, so these steps must NOT be folded into one ( ... ) block.
setlocal
set "CC_CWD_FILE=%TEMP%\cc_cwd_%RANDOM%%RANDOM%.txt"
"%~dp0cc.exe" %*
if not exist "%CC_CWD_FILE%" exit /b
set "_cccp="
for /f "tokens=2 delims=:" %%c in ('chcp') do set "_cccp=%%c"
chcp 65001 >nul
set "_ccdir="
set /p _ccdir=<"%CC_CWD_FILE%"
del "%CC_CWD_FILE%" >nul 2>&1
if defined _cccp for /f "tokens=1 delims=. " %%c in ("%_cccp%") do chcp %%c >nul
endlocal & if not "%_ccdir%"=="" cd /d "%_ccdir%"
