@echo off
rem Copyright 2026 Dell Technologies, All Rights Reserved
rem SPDX-License-Identifier: Apache-2.0
rem
rem FDO Stage 2 inside WinPE (injected into X:\Windows\System32 by wimboot,
rem started by winpeshl.ini): network, target-disk layout, SSH host keys,
rem then fdo-endpoint.exe runs TO1/TO2 with credential reuse over TBS and
rem receives the payloads into W:\fdo. If an install.wim arrived, it is
rem applied with DISM, made bootable (bcdboot) and staged with the unattend,
rem SetupComplete.cmd and the SSH keys; then the machine powers off.
rem Everything is logged to stage2.log on the FDORES volume (if present) and
rem shown on screen.

setlocal enableextensions
set SYS=X:\Windows\System32
set RUN=%ProgramData%\fdo
mkdir "%RUN%" 2>nul

wpeinit

rem ---- results volume (test harness only) --------------------------------
set R=
for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do if exist %%d:\FDORES.TAG set R=%%d:
if "%R%"=="" (set LOG=%RUN%\stage2.log) else (set LOG=%R%\stage2.log)
echo === fdo-stage2 start %DATE% %TIME% > "%LOG%"
ver >> "%LOG%"

rem ---- Windows-side unit tests of the endpoint (cmd.exe quoting etc.) ----
if exist %SYS%\fdo-endpoint-test.exe (
    echo --- fdo-endpoint unit tests on Windows >> "%LOG%"
    pushd %TEMP%
    %SYS%\fdo-endpoint-test.exe -test.v -test.run "RunDir|DeviceIP|ShellCommand" >> "%LOG%" 2>&1
    echo unit-tests-exit=%ERRORLEVEL% >> "%LOG%"
    popd
)

rem ---- target disk: the one diskpart lists at TARGET_GB (60 GB in QEMU) ----
echo list disk> "%RUN%\dp-list.txt"
diskpart /s "%RUN%\dp-list.txt" > "%RUN%\disks.txt"
type "%RUN%\disks.txt" >> "%LOG%"
set TD=
for /f "tokens=2" %%a in ('type "%RUN%\disks.txt" ^| find " 60 GB"') do set TD=%%a
if "%TD%"=="" (
    echo ERROR: no 60 GB target disk found >> "%LOG%"
    goto :done
)
echo --- partitioning disk %TD% (GPT: ESP S:, MSR, Windows W:) >> "%LOG%"
(
echo select disk %TD%
echo clean
echo convert gpt
echo create partition efi size=260
echo format quick fs=fat32 label=System
echo assign letter=S
echo create partition msr size=16
echo create partition primary
echo format quick fs=ntfs label=Windows
echo assign letter=W
echo list volume
) > "%RUN%\dp-layout.txt"
diskpart /s "%RUN%\dp-layout.txt" >> "%LOG%" 2>&1
mkdir W:\fdo 2>nul

rem ---- SSH host keys (sent to the owner via fdo.credentials) -------------
%SYS%\fdo-endpoint.exe -gen-ssh-keys "%RUN%\ssh-host-keys" >> "%LOG%" 2>&1
dir /b "%RUN%\ssh-host-keys" >> "%LOG%" 2>&1

rem ---- FDO Stage 2 --------------------------------------------------------
echo --- fdo-endpoint (TO1/TO2, credential reuse, TPM via TBS) >> "%LOG%"
%SYS%\fdo-endpoint.exe -config %SYS%\fdo-endpoint.yaml >> "%LOG%" 2>&1
set EP=%ERRORLEVEL%
echo endpoint-exit=%EP% >> "%LOG%"
echo --- received payloads >> "%LOG%"
dir W:\fdo >> "%LOG%" 2>&1
if not "%EP%"=="0" goto :done
if not exist W:\fdo\install.wim goto :done

rem ---- Phase 3: lay down Windows ------------------------------------------
echo --- dism /apply-image (index 1) %TIME% >> "%LOG%"
mkdir W:\fdo\scratch 2>nul
dism /Apply-Image /ImageFile:W:\fdo\install.wim /Index:1 /ApplyDir:W:\ /ScratchDir:W:\fdo\scratch >> "%LOG%" 2>&1
set DE=%ERRORLEVEL%
echo dism-exit=%DE% %TIME% >> "%LOG%"
if not "%DE%"=="0" (
    if not "%R%"=="" copy /y X:\Windows\Logs\DISM\dism.log "%R%\dism.log" >nul
    goto :done
)
del /q W:\fdo\install.wim
rmdir /s /q W:\fdo\scratch

echo --- bcdboot >> "%LOG%"
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
echo bcdboot-exit=%ERRORLEVEL% >> "%LOG%"

echo --- unattend, SetupComplete, SSH host keys, agent >> "%LOG%"
mkdir W:\Windows\Panther 2>nul
copy /y W:\fdo\unattend.xml W:\Windows\Panther\unattend.xml >> "%LOG%" 2>&1
mkdir W:\Windows\Setup\Scripts 2>nul
copy /y %SYS%\SetupComplete.cmd W:\Windows\Setup\Scripts\SetupComplete.cmd >> "%LOG%" 2>&1
xcopy /y /i "%RUN%\ssh-host-keys" W:\fdo\ssh-host-keys >> "%LOG%" 2>&1
copy /y %SYS%\fdo-endpoint.exe W:\fdo\ >nul
copy /y %SYS%\fdo-endpoint.yaml W:\fdo\ >nul
dir /s /b W:\Windows\Panther W:\Windows\Setup\Scripts W:\fdo >> "%LOG%" 2>&1
echo install-staged=1 >> "%LOG%"

:done
echo === fdo-stage2 end %DATE% %TIME% >> "%LOG%"
cls
type "%LOG%"
echo.
echo Powering off in 30 seconds...
ping -n 31 127.0.0.1 >nul
wpeutil shutdown
