# TODO: Cross-Cutting (All Targets)

Items that apply to every installer path (Ubuntu, Fedora, openSUSE, ROS 2,
Windows). Per-target work stays in `TODO-<OS>-UKI.md` / `TODO-WINDOWS.md`.

## Stage 1 image size limits (fdo-uefi-rs)

- [ ] **BMO URL delivery is capped at 512 MiB per image** in fdo-uefi-rs
      (`tcp4_http.rs` `MAX_RESPONSE_BYTES`); every mode buffers the whole
      image in RAM before chainloading. Linux UKIs here are 106–290 MB (fine).
      The Windows UKI is 488 MiB (WinPE only; the Setup `boot.wim` version is
      519.6 MiB and does **not** fit), leaving ~23 MiB for Stage 2 agents.
      Inline delivery has no cap. Plan: `../fdo-uefi-rs/TODO.md` "BMO image
      size limits". Until fixed: keep every UKI under 512 MiB, or use inline.
- [ ] Inline BMO is ~40× slower when fdo-uefi-rs runs TO2 over QEMU's
      iPXE e1000e EFI driver instead of virtio-net (~1 s vs ~20 ms per
      round; a new connection every round). Harnesses with an extra Intel NIC
      must give it `romfile=`. Possibly relevant to K800 transfer times.
      `../fdo-uefi-rs/TODO.md` "Inline BMO is ~40× slower over QEMU's iPXE
      e1000e driver".
- [ ] Owner SQLite does ~20 `fdatasync` per message: keep harness work dirs
      (DB) on tmpfs; on a spinning disk a chunk round costs ~0.5 s
      (`../go-fdo/TODO.md` "Performance").

## Test harnesses on the QEMU host (found 2026-10-27, step 5 run)

- [ ] **pe2 `/tmp` is a tmpfs with per-user quota (`usrquota`).** Old run
      directories (`/tmp/fdo-installer-test-*` ~6.5 GB each, Windows WORKDIRs
      ~9.6 GB) pile up; when the quota filled mid-install, `tee qemu.log`
      and the target qcow2 (owned by the user) hit EDQUOT and the run was
      void. Harnesses should check free quota up front (~10 GB) and/or delete
      their WORKDIR on success unless `KEEP=1`.
- [ ] `test-installer-pe2.sh` leaves its `server-installer` running on :8080
      after QEMU exits; the Windows harness (fixed `FDO_PORT=8080`) then can't
      start. Stop it by PID on exit. Both harnesses hard-code 8080, so they
      can't run concurrently.
- [ ] `test-installer-pe2.sh` defaults `SSH_HOST_FWD=2222`, which the Windows
      phase-3b VM holds on pe2; pick the first free port like
      `test-windows-installer.sh`. Also no fallback for `EFI_DISK`
      (`~/efi-disk-release.img`), unlike the Windows harness.
- [ ] Build scripts take Go from `PATH`; on devvm that is 1.18 and fails on
      go-fdo-endpoint's `go 1.25.0`. Use `GO_ROOT=/home/bradgoodman/go`.

## v2: Install Back Channel ("Report Mode")

**Status:** Ubuntu PoC implemented 2026-10-14 (standalone logs per
fdo-sim 0626e68). `rootfs-installer/usr/local/bin/fdo-report` is staged into
`/run/fdo` by `20fdo-receive` and called from `config/autoinstall-test.yaml`
`late-commands` (outcome 0) and `error-commands` (outcome 2); it runs
`fdo-endpoint -report ...` (go-fdo-endpoint report mode).
`test-installer-pe2.sh` collects reports with `-payload-log-dir` and has
`FORCE_FAIL=1` for the failure path. Fedora / openSUSE / ROS 2 not wired yet.

Verified on the QEMU test host (TCG, full 2.8 GB ISO inline):

- 2026-10-19 success run: `late-commands` report, 4 logs (Subiquity server /
  client debug, curtin, journal tail) stored per GUID with `outcome: 0`.
- 2026-10-20 `FORCE_FAIL=1` run: `error-commands` report, 4 logs with
  `outcome: 2` / "install failed", no `outcome: 0` report; the Subiquity log
  and journal show the cause (`Late/run_user_supplied/command_0 ... 'false'
  returned non-zero exit status 1`). The report session rejected both
  payloads at `payload-ack` (code 3); no payload data was sent. Subiquity then
  waits at its error screen; the harness has to be stopped by hand
  (`sudo pkill -f '[q]emu-system-x86_64 .*fdo-installer-test-<ts>'`).

### Problem

Today Stage 2's `go-fdo-endpoint` runs TO2, receives the install config and
ISO, sends back SSH host keys and IP (Credentials FSIM), and exits. It only
*stages* the payloads (`/run/fdo/autoinstall/user-data`, `/dev/pmem0`; see
`rootfs-installer/scripts/casper-premount/20fdo-receive`). Only after it
exits does the vendor installer (Subiquity / Anaconda / Agama) use them. So
the Owner learns that the *media* arrived, never whether the *install*
worked. If the install fails, its logs stay on the device console and are
lost on the next power cycle.

It's the same "already hung up" gap as Stage 1 firmware BMO (see
`fdo-overview-docs/articles/fdo-bmo-already-hung-up.md`), one stage later.

Being able to see, debug and inspect the install is a major advantage of
FDO-driven installation over fire-and-forget PXE / HTTPS boot.

### Design: report on the next contact

A device may re-run the endpoint **at any time, only to return data**:

- A separate invocation ("report mode") runs TO2 with credential reuse,
  runs only the payload FSIM, and **rejects every payload** the Owner
  offers (at `payload-ack`, before any data is sent).
- It sends the files it was told to send (command-line arguments) as
  `payload-log-*` transfers, each with its own `content_type`, and exits.
- The Owner accepts or declines each log as it sees fit
  (`payload-log-ack [false, 5]` = not wanted).

When to call it is the implementation's choice. Examples:

- **Phase-specific:** at defined points in the install ("ISO mounted",
  "SSH set up", ...), carrying that phase's output.
- **When needed:** something went wrong (e.g. installer error hooks:
  Subiquity `error-commands`, Anaconda `%onerror`).
- **End of process:** one final dump (Subiquity `late-commands`, Anaconda
  `%post`, Agama post scripts).

Rejected alternative: keeping the Stage 2 endpoint and its TO2 session open
until the install finishes. The endpoint would have to survive the switch to
the installer's root filesystem, keep a session idle for 20+ minutes, and
detect each installer's completion.

### Possible later extension: real-time following

Architecturally allowed, not planned: deliver the install config, then run
report mode in parallel, following the installer's log/journal and sending
records as they appear, exiting when the install ends. In this mode the
device is in charge of transmission: it sends when it has data and
otherwise waits, so it does not poll the Owner. The cost is idle gaps that
the Owner's session / HTTP timeouts must tolerate. Owners may want to
handle such logs as record streams rather than as a file.

### Open items

- [ ] **Spec: standalone diagnostic transfer.** `chunking-strategy.md`
      "Diagnostic Payloads" defines `*-log` only inside a primary transfer
      (before `*-result`). Report mode needs a device-initiated log not tied
      to an owner payload, plus a terminal message so the Owner knows the
      device is finished. **Drafted 2026-10-14 (uncommitted, for review):**
      fdo-sim `chunking-strategy.md` "Standalone Diagnostic Transfers" (new
      `*-log-result`, owner → device) and `fdo.payload.md` "Standalone
      Diagnostics" (`payload_name` / `payload_version` correlation keys).
      Reviewed 2026-10-19 (outcome in `*-log-end` status; `standalone: true`
      required; owner-first race rule with ack reason 6 Busy); committed in
      fdo-sim 0626e68 (2026-10-19).
      Workaround that needs no spec change: the Owner offers a "report
      request" payload (e.g. `application/vnd.fdo.install-report`) in every
      session; normal phases reject it, report mode accepts it and answers
      with `payload-log-*` + `payload-result`.
- [ ] **Spec gap: owner abort of a log.** The owner can decline a log at
      `*-log-ack`, but has no way to stop one in progress (e.g. an
      open-ended, followed-live log that grows too large) short of failing
      the session. Not addressed in the 2026-10-14 draft.
- [ ] **Spec (informative): record-aligned logs.** Optional `*-log-begin`
      metadata key `record_aligned` saying each chunk holds whole records, so
      the Owner MAY process them as they arrive. `total_size` is already
      optional (open-ended until `*-end`), and `content_type` already exists.
      Drafted 2026-10-14 with the item above (chunking-strategy.md
      "Record-Aligned Logs").
- [x] **go-fdo-endpoint: report mode.** `-report <file>` (repeatable) plus
      `-report-phase/-outcome/-message/-payload-name/-payload-version/
      -max-size` (`report_mode.go`), unit-tested in `report_mode_test.go`
      (incl. an in-memory run against go-fdo's owner; mutation-checked
      2026-10-21). Still open: `SendOnSuccess` for
      *nested* handler logs is only a struct field (`payload_diagnostics.go`).
- [x] **go-fdo.** Standalone logs on both sides (`fsim/payload_owner.go`,
      `fsim/payload_device.go`: `StandaloneLogs`, `ReportOnly`); example
      server stores them per GUID with a `.json` sidecar; example client
      `-payload-report`; `./test_examples.sh payload-log-standalone`.
- [x] **fdo-uki-build plumbing (Ubuntu).** See Status above.
- [ ] **Plumbing for the other targets** (deferred 2026-10-21): Anaconda
      `%post` / `%onerror` (Fedora), Agama post scripts (openSUSE), ROS 2
      autoinstall. Same pattern as Ubuntu: stage `fdo-endpoint` + config +
      `fdo-report` where the installer can reach them, call `fdo-report`
      from the success and error hooks, extend each `test-<os>-installer.sh`
      with `-payload-log-dir` and a forced-failure option.
- [ ] **Owner correlation** (deferred 2026-10-21). Device GUID is done
      (reports are stored per GUID). Still missing: which payload a report
      is about. The endpoint already has `-report-payload-name` /
      `-report-payload-version` and the Owner stores them in the `.json`
      sidecar, but `fdo-report` never passes them, so they are empty. The
      Stage 2 endpoint knows the autoinstall payload's name/version (from
      `payload-begin`) but does not persist them; record them in `/run/fdo`
      during Stage 2 and have `fdo-report` pass them. Optionally a hash.
- [ ] **Failure modes.** A hard crash (kernel panic mid-install) sends no
      report; the only signal is the device returning to Stage 1. Persisting
      logs across a reboot needs persistent storage the installer
      environment may not have.
- [ ] **Later stages.** The installed OS (first boot or management agent,
      `doc/MANAGED-EDGE.md`) can use the same report mode.
