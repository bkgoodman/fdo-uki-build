// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

//go:build !windows

package main

import "github.com/fido-device-onboard/go-fdo/tpm"

const transportName = "tpm.DefaultOpen (FDO_TPM_DEVICE or /dev/tpmrm0)"

func openTPM() (tpm.Closer, error) { return tpm.DefaultOpen() }
