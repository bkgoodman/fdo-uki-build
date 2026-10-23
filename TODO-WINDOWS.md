# TODO: FDO Windows Installer (WinPE)

Target: **Windows Server 2025** (evaluation ISO for development).
Constraint: **Linux-only tooling** (wimlib, xorriso); no Windows build host,
no ADK, no DISM on the build side.

Same three stages as the Linux targets ([README.md](README.md#how-it-works)):

1. **Stage 1 (firmware):** fdo-uefi-rs receives one EFI binary over BMO and
   chainloads it. The binary is a "Windows UKI": a small stub that carries
   wimboot, the vendor's untouched `boot.wim`, and the injected FDO files,
   presents them as an in-memory read-only file system, and starts wimboot,
   which starts `bootmgfw.efi` → WinPE in a RAM disk. Not a Linux UKI, but
   the same idea: one owner-delivered EFI file, no disk, no bootloader.
2. **Stage 2 (WinPE):** `startnet.cmd` (injected by wimboot into
   `X:\Windows\System32`): `wpeinit` → `diskpart` (GPT: ESP, MSR, Windows)
   → `fdo-endpoint.exe` (TPM via TBS, credential reuse) receives
   `unattend.xml`, then streams `install.wim` to the NTFS partition → `dism
   /apply-image` → `bcdboot` → `unattend.xml` into `\Windows\Panther` →
   stage report-mode files → `wpeutil reboot`.
3. **Stage 3 (Windows setup):** specialize/OOBE runs unattended;
   `SetupComplete.cmd` calls `fdo-endpoint -report` (back channel). SSH host
   keys from Stage 2 go to `C:\ProgramData\ssh` (OpenSSH Server is in-box on
   Server 2025).

Stage 1 alternatives considered (see workstream `windows-install`):

- **A** — the in-memory file system lives in fdo-uefi-rs and BMO carries a
  multi-file bundle. Needs a new BMO image type (spec change) and Stage 1
  client changes. Not chosen: A′ needs neither.
- **B** — BMO `application/x-iso9660-image` (already in the spec), registered
  with `EFI_RAM_DISK_PROTOCOL`, boot `\EFI\BOOT\BOOTX64.EFI` from it. Generic
  (any ISO), but depends on firmware RamDiskDxe. Possible later feature.

## Phase 0: Discovery (spikes on the QEMU test host, KVM)

Done 2026-10-22, all positive. Details, hashes and timings:
[TEST-WINDOWS.md](TEST-WINDOWS.md). Spike tools: `windows/tbs-probe/`,
`windows/spike/`.

- [x] Install build tools on the build host: `wimtools xorriso`
- [x] Pin the Server 2025 evaluation ISO: `config/windows-installer.env`
- [x] Inspect the Setup `sources/boot.wim`: **both indexes carry
      `tbs.dll`, `tpm.sys`, `Win32_Tpm`, `manage-bde`** (SecureStartup), plus
      diskpart, DISM, bcdboot, drvload, NVMe/AHCI. Linux-only path confirmed.
- [x] ~~WinRE fallback~~: not needed
- [x] wimboot boot under OVMF: OVMF boots wimboot as the removable path;
      wimboot extracts `bootmgfw_EX.efi` from the stock WIM; injected
      `winpeshl.ini` + script run at startup. WinPE in 20 s under KVM.
- [x] WinPE NIC in QEMU: **e1000e in-box** (82574L, DHCP OK); virtio is not
- [x] TBS in WinPE: go-fdo `tpm` package over `windowstpm` reads the DCTPM
      credential, loads the DAK, signs, HMACs: identical to Linux on the
      same TPM state
- [x] TBS command blocking: nothing needed for credential reuse is blocked.
      NV define/write (no `-reuse-cred`) not tested.
- [ ] (B evaluation only, deferred) `drivers` / `dh -p` in the EFI shell on
      OVMF and on the K800: is a RAM disk driver present?
- [ ] Extract `boot.wim` without a loop mount (UDF; `xorriso` sees only the
      ISO9660 `README.TXT`). Options: keep `sudo mount` like the other
      builders, or `7z`.

## Phase 1: Stage 1 boot

- [x] Windows-UKI stub: new repo **`../winpe-uki-stub`** (2026-10-22).
      Sections `.wimboot` / `.files` (newc cpio) / `.cmdline`, read-only
      in-memory `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`, `LoadImage` wimboot from
      buffer with `DeviceHandle` set, `StartImage`. `tools/mkuki.sh`
      assembles with objcopy. 16 unit tests; clippy clean.
- [x] Boot a UKI under OVMF from the ESP (no FDO yet): 545 MB single EFI
      (stub + wimboot + stock boot.wim + spike files) → WinPE in 27 s, TBS
      probe matches Linux ([TEST-WINDOWS.md](TEST-WINDOWS.md))
- [ ] `build-windows-installer.sh`: fetch + verify ISO, extract `boot.wim`
      (stock, unmodified), build `fdo-endpoint.exe`, run `mkuki.sh`
- [ ] Memory check: about 3× the image at chainload time (download buffer,
      loaded image, bootmgr RAM disk). 4 GiB was enough for 488 MiB; find
      the floor, and check the K800's RAM.
- [x] Deliver via BMO **URL** mode, SHA-256 pinned in signed image-begin
      (then `windows/spike/start17-winpe-uki.sh`, now `test-windows-installer.sh`)
- [x] QEMU: Stage 1 TO2 → stub → wimboot → WinPE, probe over TBS matches
      (65 s; [TEST-WINDOWS.md](TEST-WINDOWS.md))
- [x] Boot WinPE (index 1) rather than Setup (index 2):
      `wimlib-imagex export boot.wim 1 winpe.wim --boot`; 488 MiB UKI
- [ ] **fdo-uefi-rs 512 MiB HTTP body cap** (`tcp4_http.rs`
      `MAX_RESPONSE_BYTES`): only ~23 MiB headroom once Stage 2 agents
      (fdo-endpoint.exe ~15 MiB) are added. Tracked in fdo-uefi-rs `TODO.md`.
- [x] **Inline** delivery of the 488 MiB Windows UKI (signed): 151 s,
      WinPE + TBS probe PASS (no 512 MiB cap; URL is faster: 13 s)
- [ ] Meta-URL delivery (go-fdo-meta-tool) for the Windows UKI
- [ ] Real hardware (K800): Stage 1 chainload of the Windows UKI

## Phase 2: go-fdo / go-fdo-endpoint on Windows

- [x] go-fdo: `tpm/open_windows.go` (`windowstpm.Open()` via TBS), build
      tag `windows && !tpmsim && !tinygo` (2026-10-22, approved). Verified:
      tpm package builds for linux / linux+tpmsim / windows / darwin;
      go-fdo-endpoint builds for windows±tpm and linux±tpm; `go vet` and
      golangci-lint (linux + windows) clean; tpm unit tests pass.
      Uncommitted in go-fdo.
- [x] go-fdo-endpoint on Windows (2026-10-22, uncommitted): `shellCommand()`
      (`shell_unix.go` / `shell_windows.go`, `cmd.exe /S /C` with a verbatim
      command line), `fdoRunDir()` (`/run/fdo` / `%ProgramData%\fdo`,
      `FDO_RUN_DIR`), `deviceIP()` falls back to interface addresses.
      Unit tests `run_dir_test.go` pass on Linux and **inside WinPE**
      (`fdo-endpoint-test.exe`). Streaming handler needed no change.
- [x] Endpoint config for Windows: `windows/stage2/fdo-endpoint.yaml`:
      `application/vnd.microsoft.unattend+xml` → `W:\fdo\unattend.xml`,
      `application/vnd.microsoft.wim` → `W:\fdo\install.wim`
- [x] Stage 2 script `windows/stage2/fdo-stage2.cmd`: wpeinit, finds the
      60 GB target disk, diskpart GPT (ESP `S:`, MSR, NTFS `W:`), SSH host
      keys, endpoint, log to `stage2.log`
- [x] Interop on QEMU: Stage 2 TO1/TO2, credential reuse, TPM via TBS;
      unattend + 300 MB `.wim` stand-in streamed to NTFS; SSH keys registered
      ([TEST-WINDOWS.md](TEST-WINDOWS.md))
- [ ] Owner MIME type for unattend: `application/vnd.microsoft.unattend+xml`
      is ours, not registered; settle it in fdo-sim `fdo.payload.md` (which
      already lists `application/vnd.microsoft.wim`)
- [ ] Report mode on Windows: Linux uses the `fdo-report` shell script; needs
      a `.cmd` equivalent (or call `fdo-endpoint.exe -report` directly) from
      the failure path and from `SetupComplete.cmd`
- [x] Stage 2 UKI was 502 MiB (9 MiB headroom); the builder leaves out
      `fdo-endpoint-test.exe` unless `ENDPOINT_TESTS=1`: 494 MiB, 18 MiB headroom

## Phase 3: Full flow (QEMU, KVM)

Done 2026-10-22 ([TEST-WINDOWS.md](TEST-WINDOWS.md) "Phase 3").

- [x] `fdo-stage2.cmd`: after the endpoint, `dism /Apply-Image` (index 1,
      scratch on `W:`), `bcdboot W:\Windows /s S: /f UEFI`, unattend →
      `\Windows\Panther`, `SetupComplete.cmd` → `\Windows\Setup\Scripts`,
      SSH host keys + agent → `W:\fdo`, power off
- [x] Image: Server 2025 **Standard Core** (install.wim index 1) exported
      with wimlib, 3,157,707,632 B; owner payload order unattend → wim →
      authorized key
- [x] Test answer file, now `config/unattend-test.xml` (specialize: ComputerName,
      TimeZone; oobeSystem: locale, OOBE hide pages, Administrator password)
- [x] `SetupComplete.cmd`: FDO SSH host keys → `C:\ProgramData\ssh`
      (ACL SYSTEM + Administrators only), owner-delivered
      `administrators_authorized_keys`, sshd auto + started, firewall rule,
      marker; removes the private-key staging copies and the plaintext
      unattend copies
- [x] Harness `INSTALLED_BOOT=1`: boots the target disk alone, SSH with
      `StrictHostKeyChecking=yes` against only the fdo.credentials host keys,
      negative control with a wrong key, every run archived
- [x] Installed system boots; SSH host keys = FDO-registered keys (no TOFU)
- [x] Later boots: cold boot and in-OS reboot both come back with sshd
      (auto-start) and the same FDO host keys; with the FDO client disk still
      attached the firmware boots Windows Boot Manager (bcdboot made it
      first). `boot-installed-windows.sh`
- [ ] Re-provisioning policy: what makes a deployed machine run Stage 1
      again (boot-order change, owner action, wipe)? Today nothing does,
      which is right for "installed", but needs a deliberate story
- [ ] Failure path ends in a report (report mode, Phase 4)
- [ ] Desktop Experience (index 2) and Datacenter: same flow, larger image
- [x] Two password modes (2026-10-23): demo answer file keeps its plaintext
      password (advised against); without `AdministratorPassword` the
      device goes SSH-only (`windows/answerfile/fdo-answerfile.exe` adds a
      random password for setup, SetupComplete makes sshd key-only).
      Tested both ways (`ANSWER_MODE=password|ssh-only`)
- [ ] Owner-generated per-device password option (kept in the owner's
      records) as a middle ground between demo and SSH-only
- [ ] Per-device answer files from a template on the owner side
      (ComputerName etc. from the owner's inventory / device GUID), like
      autoinstall/kickstart per device on Linux
- [ ] Answer-file options worth exercising: product key, domain join,
      RDP / WinRM, `RunSynchronous` / `FirstLogonCommands` (README-WINDOWS.md
      "The answer file")
- [x] **Scripted (2026-10-23):** `build-windows-installer.sh` (ISO +
      wimboot verify, cached WIM exports, image content checks, agent +
      stub builds, reproducible UKI, answer-file check; `DEPLOY=1`,
      `TEST=1`) and `test-windows-installer.sh` (~24 asserted checks,
      `RESULT: PASS|FAIL` exit status, run archive, free-port selection);
      `boot-installed-windows.sh` at the repo root
- [x] Negative-test the harness itself: `BAD_UKI_HASH=1` (owner signs a
      wrong UKI hash): device refuses to chainload, run FAILs with exit 1
- [ ] More negative legs: wrong install-image hash (Payload FSIM must
      reject), answer file with a different ComputerName than expected
- [ ] shellcheck the Windows scripts (not installed on the build or test host)

## Phase 4: Hardening / Production

- [ ] Report mode from `SetupComplete.cmd` (and an error path)
- [ ] Installed-OS TPM: Windows TPM provisioning (owner/lockout auth) vs
      FDO credential operations for report mode / a later management agent
- [ ] K800 bare metal: Intel NIC + NVMe drivers in WinPE
- [ ] Secure Boot: wimboot and bootmgfw are signed; the stub and fdo-uefi-rs
      are not
- [ ] Licensing: the owner supplies licensed media; the "vendor ships the
      UKI" story does not carry over to Microsoft
- [ ] Other editions: Windows 11 IoT Enterprise LTSC
