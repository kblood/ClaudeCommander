@ECHO OFF
REM ============================================================
REM  INSTALL.BAT  --  Build CC from source on DOS using NASM
REM  Requires: MS-DOS 6.22+ (CHOICE command), NASM on PATH
REM ============================================================

ECHO.
ECHO  Claude Commander -- DOS source installer
ECHO  =========================================
ECHO  This script assembles CC.COM from source using NASM.
ECHO  NASM must be on your PATH (type NASM and press Enter to check).
ECHO.

REM ---- Check that NASM is available ----
NASM -v >NUL 2>&1
IF ERRORLEVEL 1 GOTO NO_NASM

REM ---- Ask: LFN support? ----
CHOICE /C:YN /N "Include LFN (long filename) support? (Y/N) "
IF ERRORLEVEL 2 GOTO NO_LFN
IF ERRORLEVEL 1 GOTO YES_LFN

:YES_LFN
SET CC_LFN=1
SET CC_OUTFILE=CC-LFN.COM
GOTO ASK_MENU

:NO_LFN
SET CC_LFN=0
SET CC_OUTFILE=CC.COM
GOTO ASK_MENU

:ASK_MENU
ECHO.
REM ---- Ask: menu bar? ----
CHOICE /C:YN /N "Include menu bar? (Y/N) "
IF ERRORLEVEL 2 GOTO NO_MENU
IF ERRORLEVEL 1 GOTO YES_MENU

:YES_MENU
SET CC_MENU=1
GOTO DO_BUILD

:NO_MENU
SET CC_MENU=0
GOTO DO_BUILD

:DO_BUILD
ECHO.

REM ---- Construct flags and run NASM ----
IF %CC_LFN%==1 IF %CC_MENU%==1 GOTO BUILD_LFN_MENU
IF %CC_LFN%==1 IF %CC_MENU%==0 GOTO BUILD_LFN_NOMENU
IF %CC_LFN%==0 IF %CC_MENU%==1 GOTO BUILD_STD_MENU
IF %CC_LFN%==0 IF %CC_MENU%==0 GOTO BUILD_STD_NOMENU

:BUILD_LFN_MENU
ECHO Building with: -dFEAT_STD -dFEAT_LFN_FULL
NASM -f bin CC.ASM -dFEAT_STD -dFEAT_LFN_FULL -o %CC_OUTFILE%
GOTO BUILD_DONE

:BUILD_LFN_NOMENU
ECHO Building with: -dFEAT_STD -dFEAT_LFN_FULL (no menu bar)
NASM -f bin CC.ASM -dFEAT_CUSTOM -dFEAT_WIDGETS -dFEAT_CLOCK -dFEAT_FREE ^
  -dFEAT_VIEWS -dFEAT_TREE -dFEAT_SORT -dFEAT_COLS -dFEAT_SEARCH ^
  -dFEAT_MASK -dFEAT_MENU -dFEAT_HELP -dFEAT_EDIT -dFEAT_FIND ^
  -dFEAT_GREP -dFEAT_ZIP -dFEAT_ATTR -dFEAT_VFS -dFEAT_VIEW ^
  -dFEAT_INI -dFEAT_LANG -dFEAT_LFN -dFEAT_LFN_FULL -o %CC_OUTFILE%
GOTO BUILD_DONE

:BUILD_STD_MENU
ECHO Building with: -dFEAT_STD
NASM -f bin CC.ASM -dFEAT_STD -o %CC_OUTFILE%
GOTO BUILD_DONE

:BUILD_STD_NOMENU
ECHO Building with: -dFEAT_STD (no menu bar)
NASM -f bin CC.ASM -dFEAT_CUSTOM -dFEAT_WIDGETS -dFEAT_CLOCK -dFEAT_FREE ^
  -dFEAT_VIEWS -dFEAT_TREE -dFEAT_SORT -dFEAT_COLS -dFEAT_SEARCH ^
  -dFEAT_MASK -dFEAT_MENU -dFEAT_HELP -dFEAT_EDIT -dFEAT_FIND ^
  -dFEAT_GREP -dFEAT_ZIP -dFEAT_ATTR -dFEAT_VFS -dFEAT_VIEW ^
  -dFEAT_INI -dFEAT_LANG -dFEAT_LFN -o %CC_OUTFILE%
GOTO BUILD_DONE

:BUILD_DONE
IF ERRORLEVEL 1 GOTO BUILD_FAILED
ECHO.
ECHO  Done! Output: %CC_OUTFILE%
ECHO  Copy %CC_OUTFILE% (and cc.ini / cc.hlp / da.lng) to your DOS path.
GOTO END

:BUILD_FAILED
ECHO.
ECHO  ERROR: NASM returned an error. Check the output above.
GOTO END

:NO_NASM
ECHO.
ECHO  ERROR: NASM not found on PATH.
ECHO  Download NASM for DOS from https://www.nasm.us/
ECHO  Copy nasm.exe to a directory on your PATH (e.g. C:\NASM\) and retry.
GOTO END

:END
SET CC_LFN=
SET CC_MENU=
SET CC_OUTFILE=
