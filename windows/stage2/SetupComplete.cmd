@echo off
rem Copyright 2026 Dell Technologies, All Rights Reserved
rem SPDX-License-Identifier: Apache-2.0
rem
rem Runs once as SYSTEM at the end of Windows setup (first boot), staged by
rem fdo-stage2.cmd. Installs the SSH host keys generated in WinPE (the ones
rem the owner already received via fdo.credentials) and the owner-supplied
rem administrators_authorized_keys, then enables OpenSSH Server.

set LOG=C:\Windows\Setup\Scripts\SetupComplete.log
set SSHD=C:\ProgramData\ssh
echo === SetupComplete %DATE% %TIME% > "%LOG%"
mkdir "%SSHD%" 2>nul

if exist C:\fdo\ssh-host-keys\ssh_host_ed25519_key (
    copy /y C:\fdo\ssh-host-keys\ssh_host_* "%SSHD%\" >> "%LOG%" 2>&1
    rem sshd refuses private host keys readable by anyone but SYSTEM/Administrators.
    for %%k in ("%SSHD%\ssh_host_ed25519_key" "%SSHD%\ssh_host_ecdsa_key" "%SSHD%\ssh_host_rsa_key") do (
        icacls %%k /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" >> "%LOG%" 2>&1
    )
)
if exist C:\fdo\authorized_keys (
    copy /y C:\fdo\authorized_keys "%SSHD%\administrators_authorized_keys" >> "%LOG%" 2>&1
    icacls "%SSHD%\administrators_authorized_keys" /inheritance:r /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" >> "%LOG%" 2>&1
)

rem Remove what must not outlive setup: the private host keys' staging copy
rem (C:\fdo inherits C:\'s ACL, readable by local users) and the unattend
rem copies (plaintext Administrator password).
del /f /q C:\fdo\ssh-host-keys\ssh_host_ed25519_key C:\fdo\ssh-host-keys\ssh_host_ecdsa_key C:\fdo\ssh-host-keys\ssh_host_rsa_key >> "%LOG%" 2>&1
del /f /q C:\fdo\unattend.xml C:\Windows\Panther\unattend.xml >> "%LOG%" 2>&1
echo cleanup: private key copies and unattend removed >> "%LOG%"

rem SSH-only install (the answer file had no AdministratorPassword): the
rem account got a random password nobody knows; make sshd key-only too.
rem Options before the default config: sshd uses the first value it reads
rem (the default file ends in a Match block, so appending would not work).
if exist C:\fdo\ssh-only (
    echo mode: ssh-only ^(no answer-file password; sshd key-only^) >> "%LOG%"
    > "%SSHD%\sshd_config" (
        echo # FDO: SSH-only install - key authentication only
        echo PasswordAuthentication no
        echo KbdInteractiveAuthentication no
        echo.
    )
    type C:\Windows\System32\OpenSSH\sshd_config_default >> "%SSHD%\sshd_config"
) else (
    echo mode: password ^(answer-file Administrator password; demo only^) >> "%LOG%"
)

sc config sshd start= auto >> "%LOG%" 2>&1
net start sshd >> "%LOG%" 2>&1
netsh advfirewall firewall add rule name="FDO OpenSSH Server" dir=in action=allow protocol=TCP localport=22 >> "%LOG%" 2>&1

echo fdo-installed %DATE% %TIME% > C:\fdo-installed.txt
echo === done %DATE% %TIME% >> "%LOG%"
