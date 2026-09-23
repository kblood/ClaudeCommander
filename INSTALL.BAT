@ECHO OFF
REM ============================================================
REM  INSTALL.BAT  --  Build CC from source on DOS using NASM
REM  Requires: MS-DOS 6.0+ or FreeDOS (CHOICE command),
REM            NASM for DOS on PATH (32-bit; needs a DPMI host
REM            such as CWSDPMI.EXE beside NASM.EXE or on PATH)
REM  Run it from the folder holding CC.ASM, CCPOP.ASM and MOD\.
REM ============================================================

ECHO.
ECHO  Claude Commander -- DOS source installer
ECHO  =========================================
ECHO  This script assembles CC.COM from source using NASM.
ECHO  NASM must be on your PATH (type NASM -v and press Enter to check).
ECHO.

REM ---- Ask: LFN support? ----
CHOICE /C:YN /N "Include full LFN (long filename) support? (Y/N) "
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
REM NASM writes CCBUILD.TMP; it replaces the output file only on success.
IF EXIST CCBUILD.TMP DEL CCBUILD.TMP

REM ---- Pick the variant and run NASM ----
REM (Labels are kept to 8 chars: MS-DOS ignores the rest of a label.)
REM The pop-up menu (no menu bar) variant is CCPOP.ASM, a short wrapper
REM that defines the feature flags and includes CC.ASM, so each command
REM line stays well under the 127-character DOS limit.
IF %CC_LFN%==1 IF %CC_MENU%==1 GOTO LFNMENU
IF %CC_LFN%==1 IF %CC_MENU%==0 GOTO LFNPOP
IF %CC_LFN%==0 IF %CC_MENU%==1 GOTO STDMENU
IF %CC_LFN%==0 IF %CC_MENU%==0 GOTO STDPOP

:LFNMENU
ECHO Building with: CC.ASM -dFEAT_STD -dFEAT_LFN_FULL
NASM -f bin CC.ASM -dFEAT_STD -dFEAT_LFN_FULL -o CCBUILD.TMP
GOTO BLDDONE

:LFNPOP
ECHO Building with: CCPOP.ASM -dFEAT_LFN_FULL (no menu bar)
NASM -f bin CCPOP.ASM -dFEAT_LFN_FULL -o CCBUILD.TMP
GOTO BLDDONE

:STDMENU
ECHO Building with: CC.ASM -dFEAT_STD
NASM -f bin CC.ASM -dFEAT_STD -o CCBUILD.TMP
GOTO BLDDONE

:STDPOP
ECHO Building with: CCPOP.ASM (no menu bar)
NASM -f bin CCPOP.ASM -o CCBUILD.TMP
GOTO BLDDONE

:BLDDONE
REM NASM deletes its output on an error. If NASM is not on PATH, DOS
REM prints "Bad command or file name" and no output appears either.
IF NOT EXIST CCBUILD.TMP GOTO BLDFAIL
IF ERRORLEVEL 1 GOTO BLDFAIL
IF EXIST %CC_OUTFILE% DEL %CC_OUTFILE%
REN CCBUILD.TMP %CC_OUTFILE%
ECHO.
ECHO  Done! Output: %CC_OUTFILE%
ECHO  Copy %CC_OUTFILE%, the CC*.COM helpers and cc.ini / cc.hlp / da.lng
ECHO  to a directory on your DOS path.
GOTO END

:BLDFAIL
IF EXIST CCBUILD.TMP DEL CCBUILD.TMP
ECHO.
ECHO  ERROR: the build failed -- %CC_OUTFILE% was not changed.
ECHO  If DOS said "Bad command or file name", NASM is not on your PATH:
ECHO  get NASM for DOS from https://www.nasm.us/ , put NASM.EXE (and a
ECHO  DPMI host such as CWSDPMI.EXE) in a PATH directory and retry.
ECHO  Otherwise check the NASM messages above.
GOTO END

:END
SET CC_LFN=
SET CC_MENU=
SET CC_OUTFILE=
