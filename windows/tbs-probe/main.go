// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

// tbs-probe: read-only check that the FDO TPM credential written by Stage 1
// (fdo-uefi-rs) or quick-di-tpm is usable through a given TPM transport.
// Run it on Linux and inside WinPE (TBS) against the same TPM state; the
// GUID, DCTPM hash, DAK public key and HMAC output must be identical.
// It never writes to the TPM.
package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/fido-device-onboard/go-fdo/cbor"
	"github.com/fido-device-onboard/go-fdo/tpm"
	"github.com/google/go-tpm/tpm2"
)

// Fixed input so HMAC output can be compared across runs and platforms.
const hmacInput = "fdo-tbs-probe-v1"

func main() {
	failed := false
	check := func(name string, err error) bool {
		if err != nil {
			fmt.Printf("FAIL %-22s %v\n", name, err)
			failed = true
			return false
		}
		return true
	}

	t, err := openTPM()
	if !check("open", err) {
		os.Exit(1)
	}
	defer func() { _ = t.Close() }()
	fmt.Printf("OK   %-22s %s\n", "open", transportName)

	if caps, err := (tpm2.GetCapability{
		Capability:    tpm2.TPMCapTPMProperties,
		Property:      uint32(tpm2.TPMPTManufacturer),
		PropertyCount: 1,
	}).Execute(t); check("GetCapability", err) {
		if props, err := caps.CapabilityData.Data.TPMProperties(); err == nil && len(props.TPMProperty) > 0 {
			v := props.TPMProperty[0].Value
			fmt.Printf("OK   %-22s manufacturer=%q\n", "GetCapability", string([]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}))
		}
	}

	info, err := tpm.ReadNVCredentials(t)
	if check("NV_Read DCTPM", err) {
		sum := sha256.Sum256(info.RawDCTPM)
		fmt.Printf("OK   %-22s present=%v size=%d sha256=%s dak=%v hmac=%v\n", "NV_Read DCTPM",
			info.HasDCTPM, len(info.RawDCTPM), hex.EncodeToString(sum[:]), info.HasDAK, info.HasHMACKey)
		var fields []cbor.RawBytes
		if check("DCTPM decode", cbor.Unmarshal(info.RawDCTPM, &fields)) && len(fields) > 4 {
			var magic uint32
			var guid []byte
			_ = cbor.Unmarshal(fields[0], &magic)
			_ = cbor.Unmarshal(fields[4], &guid)
			fmt.Printf("OK   %-22s magic=0x%08X guid=%s\n", "DCTPM decode", magic, hex.EncodeToString(guid))
		}
	}

	if key, err := tpm.LoadPersistentKey(t, tpm.DAKHandle); check("load DAK", err) {
		der, _ := x509.MarshalPKIXPublicKey(key.Public())
		pkSum := sha256.Sum256(der)
		fmt.Printf("OK   %-22s handle=0x%08X pubkey-sha256=%s\n", "load DAK", tpm.DAKHandle, hex.EncodeToString(pkSum[:]))

		challenge := make([]byte, 32)
		_, _ = rand.Read(challenge)
		digest := sha256.Sum256(challenge)
		sig, err := key.Sign(rand.Reader, digest[:], crypto.SHA256)
		if check("Sign (DAK)", err) {
			pub, ok := key.Public().(*ecdsa.PublicKey)
			if ok && ecdsa.VerifyASN1(pub, digest[:], sig) {
				fmt.Printf("OK   %-22s signature verifies against DAK public key\n", "Sign (DAK)")
			} else {
				check("Sign (DAK)", fmt.Errorf("signature does NOT verify"))
			}
		}
		_ = key.Close()
	}

	if h, err := tpm.NewSpecHmac(t, crypto.SHA256, tpm.HMACKeyHandle); check("HMAC (spec key)", err) {
		_, _ = h.Write([]byte(hmacInput))
		out := h.Sum(nil)
		if check("HMAC (spec key)", h.Err()) {
			fmt.Printf("OK   %-22s handle=0x%08X HMAC(%q)=%s\n", "HMAC (spec key)", tpm.HMACKeyHandle, hmacInput, hex.EncodeToString(out))
		}
		_ = h.Close()
	}

	if failed {
		fmt.Println("RESULT: FAIL")
		os.Exit(1)
	}
	fmt.Println("RESULT: PASS")
}
