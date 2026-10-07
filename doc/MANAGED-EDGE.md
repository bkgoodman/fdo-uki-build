# Putting It All Together: A Fully Managed Edge System

[← Overview](../README.md)

![Zero-touch to a fully managed edge system](fdo-managed-edge.svg)

The per-OS diagrams ([Ubuntu](fdo-uki-architecture.svg), [Fedora](fdo-uki-fedora-architecture.svg), [openSUSE](fdo-uki-opensuse-architecture.svg), [ROS 2](fdo-uki-ros2-architecture.svg)) end at "installed OS". This diagram adds one more piece, and that piece turns the work into a complete, zero-touch path from bare metal to a **fully managed edge device**. It is a simplified view: the OS-specific detail is collapsed, but the colours, chips and trace lines mean the same thing as in those diagrams.

## The missing piece is the oldest one

The FDO specification separates two things on each side (*FDO Entities and Entity Interconnection*):

- **Owner:** the **Onboarding Service** (the FDO server) and the **Management Service (DMS)**, which is your existing control plane.
- **Device:** the **ROE** (the FDO client) and the **Management Agent**.

FDO's job is to bring the agent and the DMS together, which is step ⑥, "device in service". In the diagram, FDO pieces are blue and the existing management pieces are orange, as in the spec figure.

Our multi-stage material describes FDO running at three layers: firmware (`fdo.bmo`), OS install (`fdo.sysconfig` / `fdo.payload`), and **applications** (`fdo.credentials`, "each app credentials itself to its own control plane"). The application layer is drawn last, but it was the **first** thing FDO was actually used for. A stand-alone management agent runs FDO to learn *where* its management plane is and *which credential* to use, then connects and takes orders: install, update, report telemetry, run workloads. That is plain FDO, with no BMO involved, and it is in use today. The catch is that someone still installs the agent by hand on an OS that someone installed by hand.

BMO removes both manual steps. The installed OS now **includes the agent**, and the agent's own FDO session becomes the final phase of the same chain.

## The phases

Every phase runs its own FDO client with the **same TPM device credential** (DAK from factory DI; credential reuse keeps it valid). Each phase asks only for the FSIMs it understands, so the owner serves each item only to the phase that asks for it.

| Phase | FDO client (ROE role) | Asks for | Receives / sends | Then |
| --- | --- | --- | --- | --- |
| 1. UEFI firmware | UEFI FDO module | `fdo.bmo` | ← UKI | verify hash, chainload |
| 2. Installer (UKI) | go-fdo-endpoint in the initrd | `fdo.payload`, `fdo.credentials` | ← OS config, ← OS ISO (← agent package, optional); → SSH host keys | hand off to the stock installer |
| 3. OS installation | *none* | — | — | install the OS **and the Management Agent**, enable it at boot |
| 4. First boot | FDO client embedded in the agent | `fdo.credentials` | ← agent credential + DMS URL | agent connects to the DMS: ⑥ device in service |

`fdo.credentials` appears twice, in opposite directions. In Phase 2 the device *registers* its SSH host keys with the owner (→). In Phase 4 the owner *provisions* the agent's credential to the device (←). Neither phase sees the other's data, and neither ever sees the UKI or the ISO.

## Getting the agent onto the device

Either option works, and both are ordinary OS configuration:

- **In the OS image:** the agent package sits in the ISO's own repo (or a custom repo), and the kickstart or autoinstall installs and enables it. For Fedora that's a package in `%packages` plus `services --enabled=<agent>`. For Ubuntu it's a `packages:` entry plus a `late-commands` line that enables the service. For openSUSE it's an Agama `software.packages` entry plus a chroot post script (or `init` script) that enables it.
- **As its own payload:** the owner sends the agent package as one more `fdo.payload` in Phase 2, and the config installs it from the delivered file. This lets the owner choose the agent version per device without rebuilding the ISO. The [ROS 2 path](../README-ROS2.md#theory-of-operation) does exactly this for a whole application stack: a pinned, offline apt bundle that the autoinstall installs. An agent package (and its dependencies) can ride in the same kind of bundle.

Either way, the agent itself needs no change for BMO. It already does FDO; it simply finds itself installed and starts at first boot, where it previously had to be installed by hand.

## What it takes on the owner side

- One more per-device item in the Onboarding Service: the agent credential plus the DMS URL. It's minted by, or on behalf of, the DMS, which expects to see that credential when the agent connects.
- The rendezvous blob (TO0) must still be registered when the agent runs, exactly as for Phase 2 (see [Rendezvous (TO0/TO1)](../README.md#rendezvous-to0to1)).
- Nothing else changes. The Onboarding Service is simply the setup front door of the larger management plane.

**Status:** Phases 1–3 are implemented and verified here for Ubuntu, Fedora, openSUSE and ROS 2. The ROS 2 path also shows the Phase 2 "agent as its own payload" mechanism, here for the ROS 2 stack. Phase 4 is the existing agent pattern, and this repo's test kickstart and autoinstall don't yet install an agent. Adding one is a config change on the device side plus one `fdo.credentials` entry on the owner side.