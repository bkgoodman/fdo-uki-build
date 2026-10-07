# Reference: Configuration, Server Flags, Troubleshooting

[← Overview](../README.md)

## Configuration

### Kernel Cmdline

- `console=tty0` — Video console (VNC)
- `console=ttyS0` — Serial console

### go-fdo-endpoint Config

Located at `/etc/fdo/config_generic.yaml` in the initrd (simple UKI) or `/etc/fdo/config.yaml` (installer UKI):

- FDO version: 200
- DI URL: `http://10.0.2.2:8080`
- Crypto: A128GCM, ECDH256
- Handlers: sysconfig (hostname, timezone, ntp-server), payload (json, octet-stream, text)

### Server Flags

- `-rv-bypass` — Skip rendezvous (direct TO2)
- `-reuse-cred` — Enable credential reuse protocol
- `-bmo` — Send UKI via BMO inline
- `-sysconfig` — Send sysconfig parameters
- `-payload` — Send file payloads
- `-bmo-duration <seconds>` — Advisory estimated time for BMO image transfer+apply (see below)
- `-payload-duration <seconds>` — Advisory estimated time for payload transfer+apply (see below)

### Estimated Duration (Watchdog Advisory)

Large payloads (e.g. a 2.8 GiB ISO image or a 106 MB UKI) can take a long time to transfer and apply over FDO ServiceInfo. Devices typically run internal watchdog timers during onboarding to recover from hangs. If a legitimate transfer exceeds the watchdog timeout, the device will reboot mid-transfer — a silent failure that looks like a hardware or network problem.

The `-bmo-duration` and `-payload-duration` server flags let the operator specify an advisory `estimated_duration` (in seconds) that is sent to the device in the `payload-begin` / `image-begin` message. The device MAY use this to extend its watchdog accordingly (the reference fdo-uefi-rs client doubles the value for safety margin and re-arms only if the result exceeds its default timeout).

**Who sets this value?** The estimate has two components:

1. **Apply time** — how long the device takes to process the payload after receiving it (e.g. running an installer). The person who authors the payload knows this best.
2. **Transfer time** — how long it takes to deliver the payload over the wire. This depends on payload size and link speed, which the sysadmin deploying the server knows best.

The operator should add both together. For example, a 2.8 GiB ISO on a 100 Mbit/s link takes ~240s to transfer, plus ~300s for the Ubuntu installer to run — so `-payload-duration 540` would be reasonable. On a slower 10 Mbit/s link the same ISO takes ~2400s, so `-payload-duration 2700`.

A value of 0 (the default) means "do not send this field" — the device uses its built-in default watchdog.

**Example:**

```bash
# BMO stage: 106MB UKI, fast link, ~30s transfer + trivial chainload
./fdo-server serve ... -bmo-duration 60

# Payload stage: 2.8GB ISO, moderate link, ~5 min transfer + ~5 min install
./fdo-server serve ... -payload-duration 600
```

## Troubleshooting

### TPM Socket Issues

QEMU 10.2.1 has compatibility issues with swtpm sockets. Use the full test script instead of running QEMU separately.

### Credential Reuse

Ensure the server has `-reuse-cred` flag. Without it, go-fdo-endpoint will generate a new credential each time, breaking the multi-stage flow.

### VNC Connection

VNC display is configurable via `VNC_DISPLAY` environment variable. If connection fails, check that QEMU is running:

```bash
ps aux | grep qemu
```