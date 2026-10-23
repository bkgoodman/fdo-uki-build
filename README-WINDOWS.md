# Windows Server 2025 Installer (FDO "Windows UKI")

[← Overview](README.md) · Test results: [TEST-WINDOWS.md](TEST-WINDOWS.md) · Work tracker: [TODO-WINDOWS.md](TODO-WINDOWS.md)

![FDO Windows Architecture](doc/fdo-uki-windows-architecture.svg)

## Building and Testing

The Windows path boots Microsoft's own **WinPE** (from the Setup `boot.wim` of the Windows Server 2025 evaluation ISO). WinPE runs go-fdo-endpoint, which receives an `unattend.xml` and an `install.wim`, applies the image with DISM and makes the disk bootable. Windows then finishes setup on its own. Everything is built on Linux; there is no Windows build host, no ADK and no DISM on the build side. For the full picture, see the [Windows architecture diagram](doc/fdo-uki-windows-architecture.svg) and [Theory of Operation](#theory-of-operation).

```bash
GO_ROOT=/path/to/go1.25 ./build-windows-installer.sh
```

The script:

1. Downloads and verifies the pinned ISO (SHA-256, size, UDF label) and wimboot (SHA-256); config in `config/windows-installer.env`.
2. Loop-mounts the ISO read-only (the only `sudo` step; the ISO is UDF, so `xorriso` can't read it). It checks `boot.wim` against its pinned hash and exports, with wimlib and no recompression:
   - WinPE (`boot.wim` index `WINPE_INDEX`)
   - the edition `INSTALL_INDEX`, checked by name against `INSTALL_IMAGE_NAME`

   Exports are cached per ISO hash and index (`FORCE=1` re-exports).
3. Checks the exported images for what the flow relies on: the TPM stack (`tbs.dll`, `tpm.sys`, `Win32_Tpm`), diskpart, DISM, bcdboot, wpeinit, the boot files, and OpenSSH Server in the install image.
4. Builds `fdo-endpoint.exe` (`GOOS=windows -tags=tpm`) and `winpe-uki-stub` (`make release` in `../winpe-uki-stub`).
5. Converts the Stage 2 files to CRLF and builds the Windows UKI with `mkuki.sh`. It reports the headroom under fdo-uefi-rs's 512 MiB URL-delivery cap, and warns if the UKI is over it.
6. Checks the answer file (well-formed XML with a `ComputerName`), then writes `build-windows/SHA256SUMS` with the component revisions.

```text
firmware/windows-server-2025-fdo.efi                 Windows UKI (BMO)               ~494 MiB
firmware/windows-server-2025-standard-core.wim       install image (Payload)         3.16 GB
firmware/unattend-test.xml                           answer file (Payload, CRLF)
```

Extra host tools: `wimtools` (wimlib), `mtools`, GNU `cpio`, `rsync`, Rust nightly (for the stub). `ENDPOINT_EXE` / `STUB_EFI` take prebuilt binaries; `ENDPOINT_TESTS=1` also injects the endpoint's Windows unit tests, which `fdo-stage2.cmd` then runs in WinPE.

```bash
DEPLOY=1 DEPLOY_HOST=<hostname> ./build-windows-installer.sh          # copy payloads + test scripts
DEPLOY=1 TEST=1 DEPLOY_HOST=<hostname> ./build-windows-installer.sh   # ... and run the test there
./test-windows-installer.sh          # on the test host (in ~/fdo-windows after DEPLOY)
./boot-installed-windows.sh <run dir> [--reboot-test] [--keep]   # boot an archived installed disk (KEEP_DISK=1)
```

`DEPLOY=1` uses `rsync --checksum`, so the 3 GB image only crosses the network when it changed. The payloads go to `DEPLOY_FIRMWARE_DIR` (`/tmp/fdo-firmware-server`). `test-windows-installer.sh`, `boot-installed-windows.sh`, `windows/view.py` and the env file go to `~/fdo-windows`. With `TEST=1` the builder runs the test on the host, copies the run archive back to `build-windows/runs/<run>/` (open `view/index.html`), and **exits with the test's status**.

The test host needs `qemu-system-x86_64` with KVM, OVMF, `swtpm`, `mtools`, the FDO server (`server-installer`), `quick-di-tpm` and the UEFI client disk `efi-disk-release.img`. `test-windows-installer.sh`:

1. Does DI with a software TPM, then starts the owner with the Windows UKI (BMO; URL with SHA-256 in a signed image-begin by default, or `DELIVERY=inline`), the answer file, the install image and a fresh harness SSH key (Payload), and registers TO0.
2. Runs the device VM through Stage 1 and Stage 2 until it powers itself off.
3. Boots the installed disk **alone** and logs in over SSH with `StrictHostKeyChecking=yes` against only the host keys the owner received over fdo.credentials.
4. Asserts every step, about 25 checks: TO0; Stage 1 TO2, BMO integrity and chainload; Stage 2 TO2 with credential reuse, payloads hash-checked by the owner, DISM, bcdboot; installed hostname = the answer file's `ComputerName`, `SetupComplete.cmd` ran, sshd running and auto-start, no private-key or answer-file copies left behind, host key ACL; and a wrong-host-key negative control that must be refused.
5. Prints `RESULT: PASS` or `RESULT: FAIL` and exits 0 or 1. Every run is archived to `~/fdo-windows-runs/<timestamp>[-RUN_TAG]/`, with `result.txt`, the logs, and `view/` (screenshots, milestones, serial log, `stage2.log`, `installed-check.log`). The last line is `ARCHIVE: <dir>`.

While it runs, `windows/view.py` serves a live page on `127.0.0.1:8099` and the VM screen is on VNC. If the default SSH-forward (2222) and VNC ports are taken, it uses the next free ones, so it can run next to a VM you're using. Options are in the script header (`DELIVERY`, `BMO_SIGN`, `INSTALL=0` for delivery only, `KEEP_DISK=1`, NIC choices, timeouts).

**Verified end to end in QEMU on 2026-10-22:**

- TO1/TO2 in both stages (Stage 2 with credential reuse, TPM via Windows TBS)
- BMO of the Windows UKI (502 MiB then, 494 MiB without the test binary), by URL (signed image-begin with SHA-256, ~10 s) and inline (~2.5 min)
- the 3.16 GB `install.wim` streamed to NTFS (~29 MB/s), DISM apply (51 s), bcdboot
- first boot: specialize/OOBE from the unattend, `SetupComplete.cmd`, sshd up ~41 s after power-on; bare machine to SSH in ~5 minutes
- SSH host keys identical to the FDO-registered keys, strict host-key checking with no TOFU; a wrong key is refused
- later boots (cold and in-OS reboot) keep sshd and the keys; with the FDO client disk still attached, the firmware boots Windows Boot Manager

See `TEST-WINDOWS.md` for hashes, timings and every failure found along the way, and `TODO-WINDOWS.md` for remaining work.

## Theory of Operation

The FDO side is the same as for the Linux targets: TO1/TO2 in both stages, BMO, Payload FSIM, Credentials FSIM, credential reuse, and a TO0-registered rendezvous blob. Everything around the installer is different, because Windows is not a kernel plus an initrd.

### At a Glance

- **Build time:** export WinPE (`boot.wim` index 1) and one edition (`install.wim` index 1, Standard Core) from the ISO with wimlib, leaving Microsoft's files untouched. Pack WinPE, wimboot and the FDO files (agent, scripts, config) into **one EFI binary** with `winpe-uki-stub`: the "Windows UKI", ~494 MiB.
- **Server:** Windows UKI (BMO), `install.wim` (Payload, `application/vnd.microsoft.wim`), **`unattend.xml`** (Payload, `application/vnd.microsoft.unattend+xml`, sent first), the admin's SSH public key (Payload), voucher, RV blob.
- **Stage 1 (UEFI):** TO1 → TO2 → BMO → chainload, exactly as for the other targets. fdo-uefi-rs is unchanged.
- **Stage 2 (WinPE):** the stub starts wimboot. wimboot starts Microsoft's boot manager on the WIM and injects the FDO files. `winpeshl.ini` runs `fdo-stage2.cmd`, which:
  - partitions the target disk and generates SSH host keys
  - runs TO1 → TO2 and receives the unattend, `install.wim` and admin key onto the new NTFS volume, returning the SSH keys
  - applies the image with DISM, runs bcdboot, stages the unattend and `SetupComplete.cmd`, and powers off
- **Stage 3 (Windows first boot):** specialize and OOBE run from the unattend. `SetupComplete.cmd` installs the FDO host keys for sshd, installs the admin key, starts sshd and removes everything sensitive left from staging.

### Linux targets → Windows mapping

| Concern | Linux targets (Ubuntu, Fedora, openSUSE, ROS 2) | Windows Server 2025 |
| --- | --- | --- |
| Boot artifact | UKI: systemd EFI stub + kernel + initramfs + cmdline | "Windows UKI": `winpe-uki-stub` + wimboot + WinPE WIM + injected files |
| Builder | `objcopy` onto `linuxx64.efi.stub` | `winpe-uki-stub/tools/mkuki.sh` (`objcopy` onto `winpe-uki-stub.efi`) |
| Vendor environment | installer initramfs (casper / dracut) | WinPE (`boot.wim` index 1) in a RAM disk |
| FDO hook | initramfs hook / systemd unit | `winpeshl.ini` → `fdo-stage2.cmd` |
| How FDO files get in | appended cpio / repacked initramfs | wimboot injects them into `X:\Windows\System32` at boot; the WIM is never edited |
| TPM access | `/dev/tpmrm0` | TBS (`tbs.dll`), go-fdo `tpm/open_windows.go` |
| Install media | full vendor ISO streamed into RAM (`/dev/pmem0`) | one exported edition (`install.wim`) streamed onto the target disk |
| Unattended config | autoinstall YAML / kickstart / Agama JSON | `unattend.xml` → `\Windows\Panther` |
| Installer | Subiquity / Anaconda / Agama | `dism /Apply-Image` + `bcdboot`, then Windows first-boot setup |
| SSH key install | late-commands / `%post` / post scripts | `SetupComplete.cmd` (+ `icacls`) |
| Admin access | user's `authorized_keys` from the config | `administrators_authorized_keys`, delivered as a Payload |
| Sizes / QEMU RAM | UKI 106–290 MB, ISO 2.7–4.2 GiB / 8–16 GiB | UKI ~494 MiB, image 3.16 GB / 4 GiB |

### Why WinPE, wimboot and a stub

Stage 1 can only chainload one EFI binary, and Windows has no "kernel plus initrd" form. Its network-boot form is the boot manager (`bootmgfw.efi`) loading a WIM into a RAM disk, normally from PXE or a DVD.

- **wimboot** (iPXE project, Microsoft-signed) provides exactly that from memory: it reads its input files from the file system it was loaded from, extracts `bootmgfw.efi`, `BCD` and `boot.sdi` from the WIM itself, and patches extra files into `X:\Windows\System32` as the boot manager reads the WIM.
- **winpe-uki-stub** (separate repo, `../winpe-uki-stub`) is what makes it one file. It carries wimboot and a cpio of files in its own PE sections, serves the cpio as a read-only in-memory `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`, and starts wimboot on it. It's the Windows counterpart of systemd-stub: built once, with the payload added per OS release.

Because the payloads are real PE sections, the BMO hash covers the boot manager, the WIM and every injected file.

**WinPE rather than Setup:** the Setup `boot.wim` has two images, and Setup (index 2) would start `setup.exe`. Exporting index 1 gives plain WinPE, which still has DISM, diskpart, bcdboot and the TPM stack (WinPE-SecureStartup: `tbs.dll`, `tpm.sys`, `Win32_Tpm`). It is also ~30 MiB smaller, which matters because of the size limit below. The injected `winpeshl.ini` replaces the default shell, so `fdo-stage2.cmd` is the only thing that runs.

**Disk, not RAM, for the install image:** the Linux targets put the whole ISO in RAM and let the stock installer find it there. WinPE's RAM drive is small, and Windows doesn't need its ISO, only an image to apply. So Stage 2 creates the final partition layout first and streams `install.wim` onto the Windows partition. It then applies it in place and deletes it.

### Stage 2: `fdo-stage2.cmd`

1. `wpeinit` (network via WinPE's in-box Intel drivers: e1000e, I350, I219).
2. Find the target disk (`diskpart list disk`; the harness uses a 60 GB disk). `clean`, GPT: EFI system partition `S:` (FAT32, 260 MB), MSR, Windows `W:` (NTFS).
3. `fdo-endpoint.exe -gen-ssh-keys %ProgramData%\fdo\ssh-host-keys` (Go crypto; WinPE has no ssh-keygen).
4. `fdo-endpoint.exe -config fdo-endpoint.yaml`: TO1 → TO2 with credential reuse. The owner address comes from the TPM credential's RV info and the TO0 blob, as on Linux. The payload handlers (`windows/stage2/fdo-endpoint.yaml`) stream each payload to its destination on `W:`, and the Payload FSIM checks the owner's hash. Handler commands run through `cmd.exe /S /C`.
5. `dism /Apply-Image /Index:1 /ApplyDir:W:\` (scratch on `W:`), then `bcdboot W:\Windows /s S: /f UEFI`. bcdboot also puts "Windows Boot Manager" first in the firmware boot order, so the next power-on boots Windows, not Stage 1.
6. Stage the answer file with `fdo-answerfile.exe` → `W:\Windows\Panther` (password or SSH-only mode, below), `SetupComplete.cmd` → `W:\Windows\Setup\Scripts`, host keys and agent → `W:\fdo`; delete `install.wim`; `wpeutil shutdown`.

Everything goes to `stage2.log` (on the harness's results disk) and to the screen.

### The answer file (`unattend.xml`)

The answer file is Windows' per-machine configuration, like autoinstall YAML, a kickstart or an Agama profile on Linux, and here it plays the same part. It's a **per-device Payload** (`application/vnd.microsoft.unattend+xml`) that the owner sends first in Stage 2. `fdo-stage2.cmd` puts it in `\Windows\Panther\unattend.xml`, where Windows picks it up on first boot. The test file is `config/unattend-test.xml`.

An answer file is organized in *configuration passes*. Which ones apply depends on how Windows is installed:

| Pass | When it runs | Used here? |
| --- | --- | --- |
| `windowsPE` | inside Setup (`setup.exe`): disk layout, which image to install, product key, EULA | **No.** We don't run Setup; `fdo-stage2.cmd` does the same jobs with diskpart, DISM and bcdboot. This is the usual approach of deployment tools (MDT, Configuration Manager). It also keeps us on WinPE, since Setup's bigger `boot.wim` doesn't fit the 512 MiB URL cap. |
| `offlineServicing` | applying updates / drivers to the offline image | not used |
| `specialize` | first boot, before OOBE: computer name, time zone, domain join, network, RDP, `RunSynchronous` commands | **yes:** `ComputerName`, `TimeZone` |
| `oobeSystem` | first boot, OOBE: locale, which OOBE pages to skip, accounts, auto-logon, `FirstLogonCommands` | **yes:** locale, OOBE pages hidden, local Administrator password |

So the answer file is where the **Windows configuration** of a device belongs: hostname, passwords and accounts, domain join, product key, time zone, locale, RDP/WinRM, firewall and first-logon commands. Disk layout and image choice belong to the script and the owner's choice of `install.wim`. The harness checks the result: the installed hostname must equal the answer file's `ComputerName`.

**The Administrator password: two modes.** The device picks the mode from the answer file:

| Answer file | Mode | What the device does | Login |
| --- | --- | --- | --- |
| has `UserAccounts/AdministratorPassword` (the demo `config/unattend-test.xml`) | **password** (demo) | uses it as is | console and SSH with that password, and SSH with the owner's key |
| no `AdministratorPassword` (remove the `UserAccounts` element) | **SSH-only** | `fdo-answerfile.exe` (in WinPE) adds a random 32-character password from the system RNG, only to get through setup; `SetupComplete.cmd` makes sshd key-only (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`) | SSH with the owner's key only; nobody knows the password |

> **Don't ship plaintext passwords.** Password mode exists to show that the owner can set the password through FDO. A plaintext (or `<PlainText>false</PlainText>`, which is only base64) password in a delivered answer file is readable by anyone who sees the file. It travels inside the encrypted TO2 session, and `SetupComplete.cmd` deletes both answer-file copies after setup, but until then it is on the disk. Use **SSH-only** for real deployments, or have the owner generate a per-device password it keeps in its own records.

Why not simply omit the password and disable the account?
- If the answer file has no Administrator password, Windows Server's first-boot setup **stops and asks for one**, which hangs an unattended install.
- Windows refuses SSH key logins to a disabled account.

So SSH-only keeps the account enabled, with a password nobody ever learns. The random password is only on the device's disk in the staged answer file, which `SetupComplete.cmd` deletes. `test-windows-installer.sh ANSWER_MODE=ssh-only` tests this mode: it strips `UserAccounts` from the demo file, then checks that sshd offers only `publickey` and that a login with the demo password is refused.

### SetupComplete

`SetupComplete.cmd` runs once as SYSTEM at the end of first-boot setup. It:

- copies the FDO host keys to `C:\ProgramData\ssh` and restricts the private keys to SYSTEM and Administrators (Windows sshd refuses broader ACLs)
- installs the owner-delivered key as `administrators_authorized_keys` (same ACL)
- in SSH-only mode (marker `C:\fdo\ssh-only`), writes `sshd_config` with `PasswordAuthentication no` and `KbdInteractiveAuthentication no` ahead of the stock defaults
- sets sshd to auto-start, starts it, and opens 22/tcp
- **deletes** the private-key staging copies in `C:\fdo` (they inherit `C:\`'s ACL, which lets local users read them) and both unattend copies (they hold the plaintext password); the first Phase 3 run left both behind
- writes the marker `C:\fdo-installed.txt`

OpenSSH Server is part of Windows Server 2025, including Core, but is not enabled by default.

### SSH host keys without TOFU

Same model as the Linux targets ([doc/SSH-HOST-KEYS.md](doc/SSH-HOST-KEYS.md)): the keys are generated in Stage 2, before the OS exists. Their public halves travel to the owner inside the authenticated TO2 session (`fdo.credentials`, `device_info` JSON with ed25519 / ecdsa / rsa keys and the IP), and the installed system uses exactly those keys. The harness builds its `known_hosts` from the owner log only and connects with `StrictHostKeyChecking=yes`. A `known_hosts` with a different key is refused (`REMOTE HOST IDENTIFICATION HAS CHANGED`).

### Runtime Flow (Windows)

Timings are from the verified QEMU run (KVM, 4 vCPU, 4 GiB).

1. **Stage 1:** TO1 (to1d verified) → TO2 → signed BMO image-begin with URL + SHA-256 → download and hash check of the ~494 MiB UKI (~10 s) → chainload.
2. **Boot chain:** winpe-uki-stub → wimboot → `bootmgfw.efi` → WinPE (seconds).
3. **Stage 2:**
   - disk layout, SSH keys
   - TO1 → TO2: unattend, `install.wim` (3.16 GB in 1 min 47 s), admin key; SSH keys returned
   - DISM apply (51 s), bcdboot, staging; power off (~4 min since power-on)
4. **Stage 3:** power on → Windows Boot Manager → specialize, OOBE, `SetupComplete.cmd` → sshd answering (~41 s).
5. **Result:** `fdo-win-test`, Windows Server 2025 Standard Core (10.0.26100.1742). It has the FDO-registered SSH host keys and key-only admin SSH, and keeps both across reboots.

### Windows-specific gotchas

- **Size cap:** fdo-uefi-rs aborts HTTP (URL / meta-URL) downloads above 512 MiB. The UKI from the full Setup `boot.wim` is 519.6 MiB and does not fit, hence WinPE only (488 MiB); with the agent it is ~494 MiB (502 MiB with `ENDPOINT_TESTS=1`). Inline delivery has no cap. See [TODO.md](TODO.md) "Stage 1 image size limits".
- **The WIM must be named `boot.wim`:** the stock BCD loads `\sources\boot.wim`; any other name fails with `0xc000000f`. `mkuki.sh` enforces it.
- **The ISO is UDF:** its ISO9660 side holds only `README.TXT`, so `xorriso` can't extract from it. Loop-mount it like the other builders.
- **CRLF:** scripts and config injected into WinPE need CRLF line endings.
- **QEMU test setup:**
  - No `bootindex`: with an explicit boot order OVMF connects only the listed devices, so the UEFI client sees no NIC.
  - The WinPE NIC (e1000e) gets `romfile=`: with QEMU's iPXE ROM, OVMF drives it too, the client runs TO2 over it, and inline rounds become ~40× slower.
  - The firmware stage uses virtio-net, which WinPE has no driver for.
  - Keep the owner database on tmpfs: it fsyncs ~20 times per message.
- **Windows assigns no drive letter to an EFI system partition:** the harness's results volume is a "basic data" partition.
- **Licensing:** unlike the Linux ISOs, Windows media can't be redistributed, so the "vendor ships the UKI" story doesn't carry over. The owner supplies licensed media (evaluation media for development).
- **Secure Boot:** wimboot and `bootmgfw.efi` are Microsoft-signed; winpe-uki-stub and fdo-uefi-rs are not.

## Files

- `config/windows-installer.env`: pinned ISO (URL, size, SHA-256, UDF label), `boot.wim` hash, wimboot URL and hash
- `build-windows-installer.sh`: Windows build (ISO + wimboot verify, WIM exports + checks, agent + stub builds, Windows UKI; `DEPLOY=1`, `TEST=1`)
- `test-windows-installer.sh`: end-to-end test with asserted checks, `RESULT: PASS|FAIL` exit status, run archive
- `boot-installed-windows.sh`: boot an archived installed disk, re-check SSH, `--reboot-test`, `--keep`
- `config/unattend-test.xml`: test answer file (hostname, time zone, locale, OOBE, demo password; remove `UserAccounts` for SSH-only)
- `windows/answerfile/`: `fdo-answerfile.exe` (Go, unit-tested): stages the answer file in WinPE, password vs SSH-only mode
- `windows/view.py`: live / after-the-fact run viewer (screenshots, milestones, serial log, WinPE logs)
- `windows/stage2/`: what goes into the Windows UKI and onto the installed system:
  - `winpeshl.ini`: runs `fdo-stage2.cmd` instead of the WinPE shell / Setup
  - `fdo-stage2.cmd`: Stage 2 (network, disk layout, SSH keys, endpoint, DISM, bcdboot, staging)
  - `fdo-endpoint.yaml`: endpoint config (payload destinations on `W:`)
  - `SetupComplete.cmd`: first-boot SSH setup and cleanup
  - `unattend-test.xml`: Phase 2 delivery-only test payload
- `windows/spike/`: Phase 0 spikes kept for reference: `make-spike-disk.sh`, `run-spike-pe2.sh`, `fdo-spike.cmd`, `winpeshl.ini` (WinPE via wimboot from a FAT disk, TPM probe)
- `windows/tbs-probe/`: read-only TPM credential probe (go-fdo `tpm` package) for Linux and Windows
- `doc/fdo-uki-windows-architecture.svg`: architecture diagram (Windows)
- `TEST-WINDOWS.md`: discovery findings, all runs, hashes and timings
- `TODO-WINDOWS.md`: Windows phased work tracker
- Related repos: `../winpe-uki-stub` (the stub and `mkuki.sh`); `../go-fdo-endpoint` (Windows port: `shell_windows.go`, `run_dir.go`); `../go-fdo` (`tpm/open_windows.go`)
