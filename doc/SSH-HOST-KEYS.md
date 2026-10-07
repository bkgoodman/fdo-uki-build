# SSH Host Key Security

[← Overview](../README.md)

The mechanism is the same for every OS here; the examples below are from the original Ubuntu path (autoinstall late-commands, cloud-init). Fedora, openSUSE and ROS 2 do the equivalent key copy in their own config (kickstart `%post`, Agama post script, autoinstall).

## The Problem: Trust On First Use (TOFU)

Standard Ubuntu installation has a fundamental SSH security weakness:

1. The OS installs, cloud-init generates SSH host keys on first boot
2. An operator connects via SSH and sees "The authenticity of host ... can't be established"
3. The operator types "yes" — **blindly trusting** that the key belongs to the intended device

This is the TOFU problem. Between installation and first SSH connection, there is no way to verify the device's identity. A man-in-the-middle could substitute their own host key during this window.

In enterprise/datacenter environments, this is mitigated by controlled networks and out-of-band provisioning. But for edge deployments and zero-touch provisioning, the gap is real — the device may be in an untrusted network with no operator present at first boot.

## The FDO Solution

FDO onboarding provides a cryptographically authenticated channel between the device and the owner service, established before the OS is even installed. We use this channel to solve the TOFU problem:

1. **Generate keys early**: SSH host keys are generated during the installer UKI boot, inside the initramfs, before the OS installation begins. The keys are created using Go's `crypto` stdlib — no `ssh-keygen` binary is needed (the busybox initramfs doesn't have one).

2. **Transmit via FDO**: The keys are sent back to the owner service during TO2 through the `fdo.credentials` FSIM (Registered Credentials flow). This channel is already authenticated by FDO's device attestation (TPM-backed HMAC credential), so the server can trust that the keys genuinely came from the device.

3. **Install permanently**: The autoinstall's late-commands copy the keys from `/run/fdo/ssh-host-keys/` to `/target/etc/ssh/`, overwriting any keys that the installer may have generated.

4. **Prevent regeneration**: A cloud-init drop-in config (`99-fdo-preserve-ssh-keys.cfg`) is written with `ssh_deletekeys: false` and `ssh_genkeytypes: []`. Without this, cloud-init's `cc_ssh` module would delete the FDO-provided keys and generate new ones on first boot, defeating the entire purpose.

5. **Verify on connect**: The owner service now has the device's SSH host public keys. It can construct a `known_hosts` entry and verify the device's identity on the first SSH connection — no TOFU required.

## What Gets Transmitted

During TO2, the `fdo.credentials` FSIM sends:

- `ssh_host_ed25519_key.pub` — ED25519 public key
- `ssh_host_ecdsa_key.pub` — ECDSA (P-256) public key
- `ssh_host_rsa_key.pub` — RSA (3072-bit) public key
- Device IP address — for convenience (the operator can locate the device)

The private keys never leave the device.

## Implementation Details

The SSH key flow spans three repos:

| Repo | Component | Role |
| ------ | ----------- | ------ |
| `go-fdo-endpoint` | `ssh_host_keygen.go` | Generates ed25519/ecdsa/rsa key pairs in OpenSSH format (uses `golang.org/x/crypto/ssh`) |
| `go-fdo-endpoint` | `credentials_device.go` | Registers `CredentialsDevice` FSIM module, reads keys from `/run/fdo/ssh-host-keys/` |
| `go-fdo-endpoint` | `main.go` | `-gen-ssh-keys <dir>` flag to generate keys; wires `fdo.credentials` module |
| `go-fdo` | `fsim/credentials_device.go` | Core FSIM logic: receives `pubkey-request` from owner, sends `pubkey-begin/data/end` inline in `Receive()` |
| `go-fdo` | `fsim/credentials_owner.go` | Server-side: sends `pubkey-request`, receives key data, sends `pubkey-result` ack |
| `fdo-uki-build` | `generate-ssh-host-keys.sh` | Initramfs script that calls `fdo-endpoint -gen-ssh-keys /run/fdo/ssh-host-keys` |
| `fdo-uki-build` | `autoinstall-test.yaml` | Late-commands: copy keys to target, write cloud-init preservation config |

## Server-Side Key Reception: Protocol and Data Flow

The server initiates the key exchange via the `-request-pubkey` flag on the FDO server CLI:

```bash
fdo server ... -request-pubkey "device_info:device_info"
```

The format is `type:id` where `id` must match what the device expects (the endpoint's `RegisterCredentialsDevice` checks for `credentialID == "device_info"`). This causes `CredentialsOwner` to send a `pubkey-request` during TO2 ServiceInfo.

**Protocol sequence (during TO2 ServiceInfo exchange):**

```text
Server -> Device:  fdo.credentials:active = true
Server -> Device:  fdo.credentials:pubkey-request = CBOR{-1: "device_info", -2: 1}
Device -> Server:  fdo.credentials:pubkey-begin = CBOR{length, credential_id, type, ...}
Device -> Server:  fdo.credentials:pubkey-data = <chunk(s) of JSON payload>
Device -> Server:  fdo.credentials:pubkey-end = CBOR{}
Server -> Device:  fdo.credentials:pubkey-result = CBOR{status: 0, message: "..."}
Server -> Device:  fdo.credentials:active = false
```

**What the device sends** (assembled in `go-fdo-endpoint/credentials_device.go`):

The device bundles all SSH public keys and its IP address into a single JSON blob — one round-trip instead of separate requests per key type:

```json
{
  "ssh_host_ed25519_key": "ssh-ed25519 AAAA... fdo-device-host-key",
  "ssh_host_ecdsa_key": "ecdsa-sha2-nistp256 AAAA... fdo-device-host-key",
  "ssh_host_rsa_key": "ssh-rsa AAAA... fdo-device-host-key",
  "ip_address": "10.0.2.15"
}
```

The public keys are read from `/run/fdo/ssh-host-keys/*.pub` and the IP from `/run/fdo/device-ip.txt` (captured before TO2 by the casper-premount hook).

**What the server does with it** (in `go-fdo/examples/cmd/server.go`):

The `OnPublicKeyReceived` callback prints the received data to stdout:

```text
[fdo.credentials] Received public key registration:
  ID:   credential-5
  Type: 0
  Key:  {"ssh_host_ed25519_key":"ssh-ed25519 AAAA...","ip_address":"10.0.2.15"} (length: 950 bytes)
```

**Current limitation:** The server only logs the received keys to stdout (which ends up in `server.log`). There is no persistence -- no database storage, no `known_hosts` file generation, no webhook. For testing, we extract the keys from `server.log` with `grep` to build a `known_hosts` file and verify the SSH connection. Production use would need the `OnPublicKeyReceived` callback to write to a database or known_hosts file.

## Connecting to an Onboarded Device

After FDO onboarding completes, the server log contains the device's SSH host keys. To connect securely (proving you are talking to the machine that was onboarded, not an impostor):

**1. Extract the host key from the server log:**

```bash
# Find the credentials registration in the server log
grep -A5 'fdo.credentials.*Received public key' server.log.raw
```

This will show the JSON blob with `ssh_host_ed25519_key`, `ssh_host_ecdsa_key`, `ssh_host_rsa_key`, and `ip_address`.

**2. Add the host key to known_hosts:**

```bash
# Remove any stale key for this IP (if reinstalled)
ssh-keygen -f ~/.ssh/known_hosts -R <DEVICE_IP>

# Add the FDO-received host key (use any of the three key types)
echo "<DEVICE_IP> ecdsa-sha2-nistp256 AAAA..." >> ~/.ssh/known_hosts
```

**3. Connect with the onboarding key:**

```bash
ssh -i config/fdo-onboarding-key fdo@<DEVICE_IP>
```

If the connection succeeds without a host key warning, you have cryptographic proof that:

- The device on the other end holds the private half of the host key
- That host key was generated during FDO onboarding and transmitted through the authenticated TO2 channel
- No TOFU -- the device identity was verified through the FDO ownership chain, not blind trust

The `fdo-onboarding-key` (in `config/`) is the SSH user key whose public half is baked into the autoinstall YAML. Password auth is disabled (`allow-pw: false`).

## Key Technical Gotcha: FDO 2.0 Yield() vs Receive()

The Credentials FSIM was originally written assuming device modules could send data via `Yield()` (the "I have data to send" callback). This works in FDO 1.01 but **FDO 2.0's `exchangeServiceInfo20` never calls `Yield()`**. Any data that must be sent in response to an owner message must be written inside `Receive()` using the `respond` callback. This was the root cause of the "Credentials FSIM disabled" issue that blocked SSH key transmission for several days.

## Key Technical Gotcha: Cloud-init Key Regeneration

Cloud-init's `cc_ssh` module runs on every boot and, by default:

1. Deletes all existing SSH host keys (`ssh_deletekeys: true`)
2. Generates new keys for configured types (`ssh_genkeytypes: [ed25519, ecdsa, rsa]`)

Simply copying keys to `/etc/ssh/` is not enough — cloud-init will overwrite them on first boot. The fix is a drop-in config file in `/etc/cloud/cloud.cfg.d/` that sets both `ssh_deletekeys: false` and `ssh_genkeytypes: []`. Note: `ssh_genkeymodes` (which appeared in some documentation) is **not a valid cloud-init key** and is silently ignored.