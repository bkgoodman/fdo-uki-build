// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

//go:build windows

package main

import (
	"github.com/fido-device-onboard/go-fdo/tpm"
	"github.com/google/go-tpm/tpm2/transport/windowstpm"
)

const transportName = "windows TBS (tbs.dll)"

func openTPM() (tpm.Closer, error) { return windowstpm.Open() }
