# TODO: Cross-Cutting (All Targets)

Items that apply to every installer path (Ubuntu, Fedora, openSUSE, ROS 2).
Per-target work stays in `TODO-<OS>-UKI.md`.

## v2: Stage 2 Endpoint Stays Connected Until the Install Finishes

**Status:** idea, not designed. A big ask; recorded so it isn't lost.

### Problem

Today Stage 2's `go-fdo-endpoint` runs TO2, receives the install config and
ISO, sends back SSH host keys and IP (Credentials FSIM), and exits. Only then
does the vendor installer (Subiquity / Anaconda / Agama) run. So the Owner
learns that the *media* arrived, never whether the *install* worked. If the
install fails, its logs stay on the device console and are lost on the next
power cycle.

It's the same "already hung up" gap as Stage 1 firmware BMO (see
`fdo-overview-docs/articles/fdo-bmo-already-hung-up.md`), one stage later.

### Idea

Keep the endpoint (and its TO2 session) alive after the payloads that the
installer needs have been delivered:

1. Deliver the install config + ISO as today.
2. Release the installer to start, while the endpoint keeps running in the
   background with the TO2 session still open.
3. Gather installer progress and logs and send them back to the Owner, e.g.
   over the device-to-owner side of `fdo.payload` (`payload-log-*`).
4. Detect install completion (success or failure), report a final result,
   then finish TO2 (Done20 / DoneAck20) and exit.

A side benefit: the end-of-TO2 credential decision (reuse / rotate /
disable) would then come *after* the install outcome is known, rather than
before.

### Open questions / likely gaps

- [ ] **Logs not tied to a payload.** `payload-log-*` currently sends a
      payload *handler's* output after that payload is applied
      (go-fdo-endpoint `payload_diagnostics.go`, `README_Generic.md`
      "Diagnostic Log Upload"; go-fdo `fsim/payload_device.go`, server
      `-payload-log-dir`). Installer logs belong to no payload. Is a
      "pending payload" that completes only at install end enough, or is
      there an **FSIM gap** (e.g. a generic device-log or install-status
      message)? Check against the specs in `fdo-sim/fsim-repository/`.
- [ ] **Install result message.** How does the device report "install
      succeeded / failed (code, reason)"? Reuse `payload-result` for a
      sentinel payload, or define something new?
- [ ] **Session lifetime.** An install takes ~10–30 min. Does the go-fdo
      server's TO2 session survive that (session TTL, HTTP timeouts)? Is a
      keepalive needed while the installer runs, and what does ServiceInfo
      allow for "nothing to send yet"? Likely **server work**. Relates to the
      advisory durations (`-payload-duration`, watchdog advisory in
      `doc/REFERENCE.md`).
- [ ] **Owner-side logic.** The server has to keep a session open with
      nothing to send, store streamed logs, and record a final install
      status. Likely **server work** in go-fdo `examples/cmd` (or the
      onboarding service).
- [ ] **Hand-off to the installer.** The endpoint currently blocks
      `dracut-initqueue` / casper until media is ready. It would need to
      signal "media ready", let the installer continue, and keep running
      (forked or a second unit). Per-target plumbing for Subiquity,
      Anaconda, and Agama.
- [ ] **Detecting completion.** Per installer: exit status, log markers,
      the completion marker the configs already write, and so on. It also
      has to handle the installer's own poweroff/reboot: the endpoint must
      finish TO2 before shutdown (a systemd shutdown-ordering dependency),
      or the result is lost.
- [ ] **Network and memory during install.** The installer may reconfigure
      networking. The ISO is held in RAM-backed `/dev/pmem0`. Confirm the
      endpoint's connection and memory use survive the install.
- [ ] **Failure modes.** If the session drops mid-install, what does the
      Owner record? Is the next contact (a re-run of Stage 1 or Stage 2) able
      to send buffered logs, the same as the Stage 1 re-entry idea?
- [ ] **Alternative to compare.** Instead of holding the session open,
      persist install logs to the target disk and have the installed OS
      (first-boot or management agent, `doc/MANAGED-EDGE.md`) report them in
      a later TO2. Simpler on the protocol side; loses reporting when the
      install never reaches first boot.
