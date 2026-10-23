# Test Results: FDO Windows Installer (WinPE)

Work tracker: [TODO-WINDOWS.md](TODO-WINDOWS.md)

> Runs before 2026-10-23 used the spike harness `windows/spike/start17-winpe-uki.sh`
> and hand-built UKIs; both are replaced by `build-windows-installer.sh` and
> `test-windows-installer.sh` (same flow, asserted checks).

## Administrator password: demo vs SSH-only (2026-10-23)

**Result: PASS in both modes (28/28 checks each).** UKI 519,982,592 B (now
with `fdo-answerfile.exe`, 2.2 MiB; 16 MiB under the URL cap).

| Run | Answer file | Device | Evidence |
| --- | --- | --- | --- |
| `20261023-100224` (`DEPLOY=1 TEST=1`) | `config/unattend-test.xml` with its demo password | `mode=password`; SetupComplete `mode: password` | sshd offers `publickey,password,keyboard-interactive`; a real password login (SSH_ASKPASS, strict host key) with the answer-file password returns `fdo-win-test` |
| `20261023-100731-ssh-only` (`ANSWER_MODE=ssh-only`) | the same file with `UserAccounts` removed | `fdo-answerfile`: `mode=ssh-only` (random password added for setup); SetupComplete `mode: ssh-only` | sshd offers `publickey` only; the demo password is refused: `Permission denied (publickey).`; key login still works |

Setup did not stop in SSH-only mode: the random password got it through
first boot (device VM 231 s, installed boot to SSH 51 s). Unit tests for the
helper: `windows/answerfile` (9 tests, run by the builder before it builds).

## Scripted build + test (2026-10-23)

**Result: PASS (24/24 checks, exit 0).** One command on the build host:

```bash
GO_ROOT=$HOME/go DEPLOY=1 TEST=1 DEPLOY_HOST=<test host> ./build-windows-installer.sh
```

- Build: ISO + wimboot verified; WinPE and `SERVERSTANDARDCORE` exported
  (cached afterwards); content checks (TPM stack, diskpart/DISM/bcdboot,
  boot files, OpenSSH Server) passed; UKI 517,726,208 B (494 MiB, 18 MiB
  under the URL cap; no test binary).
- Deploy: payloads by `rsync --checksum` (first run sends the 3 GB image).
- Test (`~/fdo-windows-runs/20261023-093306`): device VM (Stage 1 + 2)
  233 s, installed boot to SSH 50 s, total 299 s. It chose SSH port 2223 on
  its own because a VM the user was using held 2222.
- Archive fetched to `build-windows/runs/20261023-093306/`.
- Second run (`20261023-094000`) after making `mkuki.sh` reproducible: both
  exports cached, image not re-sent, PASS (device VM 230 s).
- **Negative run** (`20261023-094522-neg-bad-hash`, `BAD_UKI_HASH=1
  TIMEOUT_QEMU=300`): the owner signed a wrong SHA-256 for the UKI. Device:
  `BMO: SHA256 MISMATCH! Downloaded image is CORRUPTED.` / `REFUSING to
  chainload`. Harness: `RESULT: FAIL`, exit 1; 13 checks FAIL (from "BMO
  image integrity verified" on), while "Stage 1: TO2 complete" still PASSes,
  as it should.

## Phase 3: zero-touch install of Windows Server 2025 Core, SSH without TOFU (2026-10-22)

**Result: PASS** (runs `phase3` and `phase3b`; the second adds the
SetupComplete cleanup). Bare QEMU machine (OVMF, swtpm, empty 60 GB disk) →
installed Windows Server 2025 Standard Core reachable over SSH with a host
key the owner learned through FDO, in **~5 minutes**.

```bash
RUN_TAG=phase3b INSTALLED_BOOT=1 TARGET_GB=60 TIMEOUT_QEMU=1800 \
SERVER_EXTRA="-payload application/vnd.microsoft.unattend+xml:$P/unattend.xml \
  -payload application/vnd.microsoft.wim:$P/install-core.wim \
  -request-pubkey device_info:device_info" \
./start17-winpe-uki.sh winpe-stage3-uki.efi
```

| Item | Value |
| --- | --- |
| Stage 2 UKI | `winpe-stage3-uki.efi` 526,748,160 B, SHA-256 `de562c5e…e4680c1c` (+ `SetupComplete.cmd`) |
| Image | `install-core.wim`: install.wim index 1 (SERVERSTANDARDCORE) exported with wimlib, 3,157,707,632 B, SHA-256 `9f64befa…ec763362` |
| Unattend | `windows/stage2/unattend.xml` (CRLF), SHA-256 `8f18e973…2c3625a9` |
| Device GUID | `cb3a5bea89b91d218fa3a9d6cb9178f6` |

Timeline (run `phase3b`, owner log + `stage2.log`):

| Step | Time |
| --- | --- |
| Stage 1: TO1/TO2, signed BMO URL image-begin → `fdo.bmo image delivered` | 14:26:28 → 14:26:38 (10 s) |
| WinPE up, `fdo-stage2.cmd` starts | 14:26:52 |
| Stage 2: `unattend.xml` applied | 14:27:07 |
| Stage 2: 3.16 GB `install.wim` streamed to `W:` (~29.5 MB/s) | → 14:28:54 (1 min 47 s) |
| Stage 2: authorized key payload, SSH host keys registered, `TO2 Completed - Credential Reuse: true` | 14:28:54 |
| `dism /Apply-Image` → `dism-exit=0` | → 14:29:45 (51 s) |
| `bcdboot-exit=0`, staging, power off | 14:29:46; WinPE VM total 235 s |
| Installed disk booted alone: specialize + OOBE + SetupComplete → sshd up, SSH verified | 41 s |

Checks over SSH (`StrictHostKeyChecking=yes`, `UserKnownHostsFile` built only
from the three host keys in the owner's `Received public key registration`
line; key auth with the owner-delivered key):

- `hostname` → `fdo-win-test` (from the unattend: specialize ran)
- `C:\fdo-installed.txt` present; `SetupComplete.log`: 3 host keys installed,
  `icacls` OK ×4, `cleanup: private key copies and unattend removed`,
  `The OpenSSH SSH Server service was started successfully`
- `sc query sshd` → `RUNNING`; `ver` → `Microsoft Windows [Version 10.0.26100.1742]`
- leftovers: `C:\fdo\ssh-host-keys` holds only the three `*.pub`;
  `C:\Windows\Panther\unattend.xml` and `C:\fdo\unattend.xml`: File Not Found
- `C:\ProgramData\ssh\ssh_host_ed25519_key` ACL: `BUILTIN\Administrators:(F)`,
  `NT AUTHORITY\SYSTEM:(F)` only
- **Negative control:** same login with a known_hosts holding a random
  ed25519 key (`HostKeyAlgorithms=ssh-ed25519`) → refused: `WARNING: REMOTE
  HOST IDENTIFICATION HAS CHANGED!`
- `shutdown /s /t 5` over SSH; installed VM exits (47 s total).

Run `phase3` (before the cleanup was added) passed the same checks but left
the private host keys in `C:\fdo\ssh-host-keys` (C:\-inherited ACL, readable
by local users) and the plaintext-password unattend in `\Windows\Panther`.
`SetupComplete.cmd` now deletes both; `phase3b` verifies it.

**Subsequent boots** (`windows/spike/boot-installed-windows.sh
runs/20261022-143109-phase3b --reboot-test`, on the preserved disk):

| Boot | SSH up | System Boot Time | sshd |
| --- | --- | --- | --- |
| 2nd (cold) | 35 s | 6:38:30 PM | RUNNING, AUTO_START |
| 3rd (`shutdown /r /t 0` from inside) | 6 s after sshd went away | 6:39:08 PM | RUNNING, AUTO_START |

Each login used `StrictHostKeyChecking=yes` against only the
fdo.credentials keys; `hostname` = `fdo-win-test` both times.

**Boot order with the FDO client disk still attached** (same NVRAM as after
install; copy-on-write overlay of the installed disk): OVMF ran
`Boot0003 "Windows Boot Manager"` (`bcdboot` put itself first in BootOrder),
not the FDO client. So a reboot of the installed machine goes to Windows,
not back into Stage 1 (which, with `-reuse-cred`, would reinstall).

The installed disk, NVRAM, swtpm state, `known_hosts.fdo` and the harness key
are preserved in `~/bkgvm/winspike/runs/20261022-143109-phase3b/` on the test
host.

Evidence on the build host: `build-windows/view-phase3/`,
`build-windows/view-phase3b/` (`view/index.html`, `view/installed/`,
`view/stage2.log`, `view/installed-check.log`, `server.log`); on the test
host `~/bkgvm/winspike/runs/`.

## Inline BMO of the Windows UKI, and why it was slow at first (2026-10-22)

**Result: PASS.** `DELIVERY=inline` (signed image-begin, owner
`-bmo application/efi:winpe-uki.efi`): 512,194,560 B in 7,833 rounds,
owner `13:58:25 Added image` → `14:00:56 fdo.bmo image delivered
successfully` = **151 s (~3.4 MB/s)**; chainload → WinPE → TBS probe
`MATCH` ×4; QEMU total 193 s. URL delivery of the same image: 13 s.

The first inline attempts crawled (~80–140 KB/s). Bisected with the Ubuntu
UKI (111,148,002 B) and the Windows UKI:

| Config (all else equal) | Result |
| --- | --- |
| harness defaults then: virtio + e1000e (iPXE ROM), DB on rotating disk | <10 % in 150 s |
| same, DB on tmpfs | <10 % in 150 s |
| test-installer's exact QEMU device set (1 virtio NIC), tmpfs, unsigned | 111 MB in **48 s** |
| harness devices, **virtio only**, tmpfs | 111 MB in **33 s** |
| harness devices, **e1000e (iPXE ROM) only** | 10 % in ~10 min |
| harness devices, virtio + **e1000e `romfile=`** (no ROM), signed | 488 MiB in **151 s** |

So: when QEMU's iPXE EFI ROM drives the e1000e, fdo-uefi-rs runs TO2 over
it and each round (new TCP connection) costs ~1 s. Signing, image type and
size, KVM/TCG and RAM made no difference. The harness now gives the e1000e
`romfile=`; WinPE still uses it through its in-box driver. Tracked in
fdo-uefi-rs `TODO.md`, including a K800 check. (Two harness bugs muddied the
first A/B runs: `${BMO_SIGN:-1}` / `${NIC:-e1000e}` treated "empty" as
"unset", so the "unsigned" and "single-NIC" runs were neither; fixed with
`${VAR-default}`.)

## Phase 2: Stage 2 in WinPE: fdo-endpoint.exe over TBS (2026-10-22)

**Result: PASS.** `start17-winpe-uki.sh` with `TARGET_GB=60` and
`SERVER_EXTRA="-payload application/vnd.microsoft.unattend+xml:unattend-test.xml
-payload application/vnd.microsoft.wim:install-test.wim -request-pubkey
device_info:device_info"`; WORKDIR on tmpfs.

| Item | Value |
| --- | --- |
| Stage 2 UKI | `winpe-stage2-uki.efi` 526,744,576 B (502 MiB), SHA-256 `e79d076f…bfb024c8`: stub + wimboot + WinPE WIM + `winpeshl.ini`, `fdo-stage2.cmd`, `fdo-endpoint.yaml`, `fdo-endpoint.exe` (go-fdo-endpoint `-tags=tpm`, stripped, 10,980,352 B), `fdo-endpoint-test.exe` (8.6 MiB) |
| Payloads | `unattend-test.xml` 540 B (`62661633…`), `install-test.wim` 314,572,800 B random (`6be70a74…`) |
| Device GUID | `5030b471dc80b4f8ba4b6d43e702fa5b` |

From `stage2.log` (WinPE) and the owner log, in order:

1. Stage 1 as before; owner `fdo.bmo image delivered successfully` 13 s after
   image-begin.
2. `fdo-endpoint-test.exe` in WinPE: `TestFdoRunDirOverrideAndDefault`,
   `TestDeviceIPPrefersFile`, `TestDeviceIPFallbackIsGlobalIPv4OrEmpty`,
   `TestShellCommandRunsPlatformShell` (`echo "quoted arg" > file` through
   cmd.exe), `TestShellCommandReportsFailure`: all PASS.
3. diskpart: 60 GB disk found, `clean`, GPT, ESP `S:` (FAT32), MSR, `W:` (NTFS).
4. `-gen-ssh-keys` into `X:\ProgramData\fdo\ssh-host-keys`.
5. `Attempting TO2 with server 1: http://10.0.2.2:8080` (from the TO0 blob);
   owner modules `[fido_alliance fdo.credentials fdo.sysconfig fdo.payload
   devmod]`; chunk size 60000 (MTU 65532).
6. `unattend-test.xml` → `Payload streamed to W:\fdo\unattend.xml`; handler
   `echo` ran through cmd.exe.
7. `install-test.wim` → `W:\fdo\install.wim`, `dir` shows 314,572,800 bytes;
   owner `fdo.payload applied successfully` (payload hash checked by the
   payload FSIM, key 8).
8. `[fdo.credentials] Public key registered successfully`;
   `TO2 Completed - Credential Reuse: true, Attestation Mode: full-owner`;
   `endpoint-exit=0`.

QEMU start → power off: **89 s**. 300 MB payload: ~10 s.

**Gotcha: owner SQLite on a rotating disk.** The first attempt (WORKDIR in
`$HOME` on pe2's spinning disk) moved the payload at ~105 KB/s. tcpdump: the
device answered within 1 ms; the owner took 0.47–0.60 s per chunk. strace of
the owner: ~20 `fdatasync` per chunk (SQLite session commits). WORKDIR now
defaults to `/tmp` (tmpfs), as in the other harnesses. Tracked in go-fdo
`TODO.md` "Performance".

## Phase 1: Stage 1 end to end: fdo-uefi-rs TO2 + BMO URL → Windows UKI → WinPE (2026-10-22)

**Result: PASS (run 4 of 4).** Harness `windows/spike/start17-winpe-uki.sh`
(+ `view.py` live viewer), on the QEMU test host, KVM, 4 GiB, OVMF 4M (no
Secure Boot), `tpm-tis` + swtpm, the fdo-uefi-rs disk `efi-disk-release.img`
(2026-10-08 build).

| Item | Value |
| --- | --- |
| UKI | `winpe-uki.efi` 512,194,560 B (488 MiB), SHA-256 `c36f9722…5668b2c2`: stub + wimboot + **WinPE-only** WIM (index 1 exported from the Setup `boot.wim` with `wimlib-imagex export --boot`, 506,627,094 B) served as `boot.wim`, + `winpeshl.ini`, `fdo-spike.cmd`, `tbs-probe.exe` |
| Owner | `server -reuse-cred -bmo-url application/efi:http://10.0.2.2:9090/winpe-uki.efi:<sha256> -bmo-sign` |
| Device GUID | `d69d44fef283cdb43cde257cf280005c` (fresh DI) |

Serial log, in order: TO1; TO2 voucher chain, Owner signature and to1d
VERIFIED; `BMO: Detected COSE_Sign1 (tag 18)`, `Provisioning signature
VERIFIED`; `BMO: Image ready for boot (512194560 bytes, integrity verified)`;
`TO2 Protocol Complete!`; `Chainloading BMO image (512194560 bytes)`;
`winpe-uki-stub 0.1.0`; `starting wimboot`; `...found WIM file boot.wim`;
`...patching WIM` (3 injected files). WinPE then ran `fdo-spike.cmd`: e1000e
DHCP 10.0.2.15, tbs-probe over TBS `RESULT: PASS`, `MATCH` on DCTPM hash /
decode / DAK key / HMAC (`8ecc2911…29a1de8`) against the Linux baseline.
QEMU start → WinPE results on screen → power off: **65 s**.

Failures on the way (all fixed in the harness or the tools):

1. **No network in firmware** (runs 1–2, `No SNP handles found`): an explicit
   QEMU boot order (`bootindex`) makes OVMF connect only the listed devices,
   so no NIC driver was bound. Fix: no `bootindex`. A second NIC is also
   needed: virtio-net for OVMF/fdo-uefi-rs, e1000e for WinPE (in-box driver).
2. **bootmgfw `0xc000000f`** (run 3): the stock BCD loads
   `\sources\boot.wim`; the WIM had been packed as `winpe.wim`.
   `mkuki.sh` now always serves the WIM as `boot.wim`.
3. **Avoided before running**: fdo-uefi-rs caps an HTTP body at 512 MiB
   (`tcp4_http.rs` `MAX_RESPONSE_BYTES`). The Setup `boot.wim` UKI is
   519.6 MiB, so the WinPE-only export was used (fdo-uefi-rs `TODO.md`).

Seeing a run: `view.py` screenshots the VM every 5 s and writes
`$WORKDIR/view/index.html` (refreshes every 3 s: latest screen, milestones,
serial tail, then WinPE's `spike.log`), `timeline.html` (every screenshot)
and `serial.txt`. Serve with the page server the script leaves running on
127.0.0.1:8099; VNC on 127.0.0.1:5907 during the run.

## Phase 1: Windows UKI (winpe-uki-stub) boots from the ESP (2026-10-22)

**Result: PASS on the first boot.** `../winpe-uki-stub` built a single
545 MB EFI file (`winpe-spike-uki.efi`, SHA-256 `5ed996a5…e735f1`): stub
(33 KiB) + `.wimboot` (v2.9.0, 76,064 B) + `.files` (cpio: stock `boot.wim`,
`winpeshl.ini`, `fdo-spike.cmd`, `tbs-probe.exe`; 0x20774000 B). The ESP held
**only** `\EFI\BOOT\BOOTX64.EFI` = that file (`make-spike-disk.sh --uki`);
same harness and VM as Phase 0.

- QEMU start → WinPE → probe → shutdown in **27 s** (vs 20 s from loose
  files on FAT).
- Serial log, in order: the stub lists its 4 files; wimboot reads them from
  the stub's file system (`Using boot.wim via 0x7dab1798 len 0x2023face`,
  `...found WIM file boot.wim`, `Using fdo-spike.cmd/tbs-probe.exe/
  winpeshl.ini via ...`), extracts `bootmgfw.efi`, `bootmgfw_EX.efi`,
  `boot.sdi`, `BCD` and fonts from the WIM, then `...patching WIM` with the
  three injected files.
- Fresh DI, GUID `527cee7371d3ebfb02d9f58b167aa1b2`; WinPE (TBS) and Linux
  baseline: `MATCH` on DCTPM hash, decode, DAK public key, HMAC
  (`c8c020ab…66333c16`); DAK signature verifies.

Not yet covered: chainload by fdo-uefi-rs over BMO (Phase 1 remaining),
peak memory, Secure Boot.

## Phase 0 spike: stock WinPE via wimboot + TPM credential over TBS (2026-10-22)

**Result: PASS.** A stock, unmodified Windows Server 2025 Setup `boot.wim`
boots via wimboot under OVMF. Files injected by wimboot run at startup.
Networking comes up with an in-box driver. go-fdo's `tpm` package, over
Windows TBS, reads the FDO credential that quick-di-tpm wrote, signs with the
DAK and computes the HMAC with **byte-identical results** to the same code on
Linux against the same TPM.

### Inputs

| Item | Value |
| --- | --- |
| ISO | `26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`, 6,014,152,704 bytes, SHA-256 `d0ef4502…8579b23d` (pinned in `config/windows-installer.env`) |
| `sources/boot.wim` | 539,228,878 bytes, SHA-256 `d048a585…aa89a9fe4`, 2 images (1 WinPE, 2 Setup = boot index), LZX |
| wimboot | v2.9.0, SHA-256 `5f067ccd…7fae8e3`; PE32+, signed by Microsoft UEFI CA 2011 |
| `tbs-probe.exe` | `windows/tbs-probe` (go-fdo `tpm` package + go-tpm `windowstpm`), SHA-256 `550fb05b…9050` |
| Spike disk | `windows/spike/make-spike-disk.sh`: GPT, FAT32 ESP (wimboot as `\EFI\BOOT\BOOTX64.EFI`, `boot.wim`, `winpeshl.ini`, `fdo-spike.cmd`, `tbs-probe.exe`) + FAT "basic data" results partition |
| Harness | `windows/spike/run-spike-pe2.sh` on the QEMU test host: QEMU 10.2.1, q35, KVM, 4 vCPU, 4 GiB, OVMF 4M (no Secure Boot), AHCI, `tpm-tis` + swtpm, `e1000e` user net |

### Inventory of the stock `boot.wim` (both indexes)

Present: `tbs.dll`, `drivers\tpm.sys`, `wbem\Win32_Tpm.dll`,
`TpmCoreProvisioning.dll`, `manage-bde.exe` (i.e. WinPE-SecureStartup),
`wpeinit`, `wpeutil`, `drvload`, `diskpart`, `Dism.exe`, `bcdboot`,
`stornvme.sys`, `storahci.sys`, `Boot\EFI\bootmgfw.efi`, `Boot\DVD\EFI\BCD`,
`boot.sdi`. Index 2 also has `sources\setup.exe`.
Absent: PowerShell, `curl.exe`, `sc.exe`, `tpmtool.exe`, `winpeshl.ini`,
virtio drivers.

NICs: QEMU `e1000` (`8086:100E`, `nete1g3e.inf`) and `e1000e` (`8086:10D3`,
`net1ix64.inf`, which also covers I350 `1521`, I217/I219 `153A`/`15B7`) are
in-box; virtio-net (`1AF4`) is not.

### Run (third attempt; first two were harness bugs)

1. Fresh swtpm, DI with quick-di-tpm: GUID `59221147da26745f1da1592afd05aa1a`.
2. Linux baseline (`tbs-probe` over the swtpm socket) and WinPE
   (`tbs-probe.exe` over TBS), same TPM state:

| Check | Linux (swtpm socket) | WinPE (TBS) |
| --- | --- | --- |
| open | `tpm.DefaultOpen` | `windows TBS (tbs.dll)` |
| DCTPM NV (`0x01D10001`) | 115 B, sha256 `2308d8b6…54d3223` | identical |
| DCTPM decode | magic `0x46444F31`, GUID `59221147…05aa1a` | identical |
| DAK `0x81020002` | pubkey sha256 `14bd598d…ec2e1422` | identical |
| Sign (DAK, random challenge) | verifies | verifies |
| HMAC key `0x81020003`, `HMAC("fdo-tbs-probe-v1")` | `3a13ceba…a36bc7` | identical |

The harness compares the lines: `MATCH` for all four deterministic checks.
Control: every run does a fresh DI with new keys. Earlier runs produced
different GUIDs/keys/HMACs (e.g. GUID `808c79d5…`, HMAC `603122f7…`), and the
WinPE output matched only the current run's values, so it came from the live
TPM.

Timing: QEMU start → WinPE → probe → `wpeutil shutdown` in **20 s** (KVM).
WinPE got DHCP `10.0.2.15` on "Intel(R) 82574L Gigabit Network Connection".

### Findings / gotchas

- wimboot extracted `bootmgfw_EX.efi` from the WIM (`Loaded bootmgfw_EX.efi
  as BOOTX64.EFI`, serial log); no `bootmgfw.efi`, BCD or `boot.sdi` needed
  on the disk.
- Neither index ships `winpeshl.ini`; injecting one gives full control of
  startup (Setup's `setup.exe` does not run).
- Windows assigns no drive letter to an ESP-typed partition: results need a
  "Microsoft basic data" partition.
- swtpm started with both `--server` and `--ctrl` makes QEMU fail with
  `tpm-emulator: Failed to send CMD_SET_DATAFD: Argument list too long`;
  restart swtpm ctrl-only for QEMU (state persists).
- TBS did not block anything credential reuse needs (GetCapability,
  NV_ReadPublic, NV_Read, ReadPublic, Sign, HMAC). NV define/write (credential
  replacement, i.e. no `-reuse-cred`) is not tested.
- The Windows ISO is UDF; its ISO9660 side contains only `README.TXT`, so
  `xorriso -osirrox` cannot extract from it. The spike used a loop mount
  (`mount -o loop,ro`, as the Linux builders do).
