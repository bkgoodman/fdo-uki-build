# TODO: FDO Ubuntu Installer UKI

## Phase 1: Simple UKI and Multi-Stage FDO

- [x] Deliver and chainload a UKI through UEFI `fdo.bmo`
- [x] Boot Ubuntu kernel/initramfs
- [x] Start networking in the custom initramfs
- [x] Run go-fdo-endpoint using the same TPM credential
- [x] Complete a second TO2 with credential reuse
- [x] Receive small sysconfig and payload FSIM data
- [x] Preserve the simple build and golden UKI as regression references

## Phase 2: Destination-Driven Payload Streaming

- [x] Add genuinely unbuffered chunked receive mode to go-fdo
- [x] Preserve buffered/unified payload behavior
- [x] Verify streamed payload hashes incrementally in constant memory
- [x] Add optional per-MIME `destination` to go-fdo-endpoint YAML
- [x] Stream destination-backed MIME types through `ChunkedPayloadHandler`
- [x] Preserve MIME types without destinations through buffered behavior
- [x] Write regular destinations through `.partial` and atomic rename
- [x] Detect block-device destinations automatically
- [x] Execute configured command after successful transfer verification
- [x] Add focused regular-file streaming/cancellation tests
- [x] Complete real 16 MiB FDO payload transfer and verify byte-identical output
- [ ] Add completion records for block-device payloads
- [ ] Add explicit destination-capacity validation for block devices
- [ ] Add integration negative tests for bad hash and interrupted TO2
- [ ] Add bounded RSS measurement to integration test
- [ ] Add file-backed streaming on the owner/server; current server still uses `os.ReadFile`
- [x] Increase endpoint receive MTU and payload chunk size; 16 MiB improved from approximately 10 minutes to 10.4 seconds
- [ ] Investigate local TO1D signature verification failure seen before direct-TO2 streaming test

## Phase 3: Separate Full Ubuntu Installer UKI

- [x] Create `build-ubuntu-installer-uki.sh` without changing `build-uki.sh`
- [x] Pin Ubuntu 26.04.1 LTS live-server ISO URL, size, version, and SHA-256
- [x] Download and verify the ISO on devvm
- [x] Extract matching `/casper/vmlinuz` and `/casper/initrd`
- [x] Preserve native Ubuntu `/init`, casper, cloud-init, and Subiquity
- [x] Add installer-specific rootfs overlay and endpoint YAML
- [x] Reconstruct concatenated `early`, `early2`, and `main` initramfs archives
- [x] Insert FDO premount hook into Ubuntu's casper `ORDER` before `20iso_scan`
- [x] Compute and embed Ubuntu-compatible `memmap=2796M!4G`
- [x] Build the installer UKI entirely on devvm
- [x] Deploy under a distinct filename without touching simple/golden artifacts

## Phase 4: Casper and `/dev/pmem0` Integration

- [x] Add `casper-premount` hook to prepare network, TPM, and pmem
- [x] Stream 2.728 GiB `application/x-iso9660-image` to `/dev/pmem0`
- [x] Complete payload size/hash validation and credential reuse
- [x] Let native casper discover `live-media=/dev/pmem0`
- [x] Mount ISO9660, squashfs layers, and construct the overlay live root
- [x] Boot systemd and reach interactive Subiquity revision 7403
- [x] Add development recovery shell on failure
- [ ] Replace direct installer TO2 with proper TO0/RV re-registration and normal TO1
- [ ] Add block-device completion records and explicit capacity checks
- [ ] Design production 120-second reboot/retry policy with persistent loop protection

## Phase 5: FDO-Delivered Autoinstall

- [x] Define `application/vnd.canonical.autoinstall+yaml`
- [x] Deliver machine-specific `user-data` before the ISO payload
- [x] Store it atomically at `/run/fdo/autoinstall/user-data`
- [x] Validate cloud-config marker and create NoCloud `meta-data`
- [x] Add casper-bottom hook to copy seed into the live root
- [x] Copy FDO payload to `/autoinstall.yaml` in the live root
- [x] Embed `autoinstall subiquity.autoinstallpath=/autoinstall.yaml` in installer UKI
- [x] Verify Subiquity revision 7403 loads and applies the FDO payload
- [x] Install onto a fresh 24 GiB disposable QEMU disk
- [x] Verify completion marker, hostname, user, kernel/initrd, and EFI files read-only
- [x] Boot the installed qcow2 and reach the `fdo-installed` login prompt
- [ ] Replace test password recipe with production secret/identity policy

## Phase 6: Production Hardening

- [ ] Test full live-server ISO transfer with bounded server/client memory
- [ ] Improve chunk size and rounds per ServiceInfo exchange
- [ ] Add transfer progress and timing metrics
- [ ] Add interrupted-transfer/reboot recovery
- [ ] Add Secure Boot signing and lockdown validation
- [ ] Validate on physical UEFI hardware
