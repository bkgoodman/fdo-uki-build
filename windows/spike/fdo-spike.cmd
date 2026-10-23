@echo off
rem Copyright 2026 Dell Technologies, All Rights Reserved
rem SPDX-License-Identifier: Apache-2.0
rem Phase 0 spike: runs inside WinPE (injected into X:\Windows\System32 by
rem wimboot). Brings up networking, runs tbs-probe against the TPM, and
rem writes everything to spike.log on the volume holding FDORES.TAG.
wpeinit
set R=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\FDORES.TAG set R=%%d:
if "%R%"=="" goto :nodisk
set LOG=%R%\spike.log
echo === fdo-spike start %DATE% %TIME% > %LOG%
ver >> %LOG%
echo --- systemdrive=%SYSTEMDRIVE% results=%R% >> %LOG%
echo --- injected files >> %LOG%
dir /b X:\Windows\System32\fdo-spike.cmd X:\Windows\System32\tbs-probe.exe X:\Windows\System32\winpeshl.ini >> %LOG% 2>&1
echo --- ipconfig >> %LOG%
ipconfig /all >> %LOG% 2>&1
echo --- tbs-probe >> %LOG%
X:\Windows\System32\tbs-probe.exe >> %LOG% 2>&1
echo probe-exit=%ERRORLEVEL% >> %LOG%
echo === fdo-spike end %DATE% %TIME% >> %LOG%
rem Show the results on screen (for screenshots / VNC), then power off.
cls
type %LOG%
echo.
echo Powering off in 20 seconds...
ping -n 21 127.0.0.1 >nul
wpeutil shutdown
goto :eof
:nodisk
echo FDORES.TAG volume not found
cmd.exe
