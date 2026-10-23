// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

// fdo-answerfile stages the owner's Windows answer file for first boot
// (runs in WinPE, from fdo-stage2.cmd). See answerfile.go for the two modes.
//
//	fdo-answerfile -in W:\fdo\unattend.xml -out W:\Windows\Panther\unattend.xml \
//	    -ssh-only-marker W:\fdo\ssh-only
//
// Prints "mode=password" or "mode=ssh-only"; exits non-zero on any error.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	in := flag.String("in", "", "answer file as delivered by the owner")
	out := flag.String("out", "", "where Windows reads it (\\Windows\\Panther\\unattend.xml)")
	marker := flag.String("ssh-only-marker", "", "file created when the install is SSH-only")
	flag.Parse()
	if *in == "" || *out == "" || *marker == "" {
		flag.Usage()
		os.Exit(2)
	}
	if err := run(*in, *out, *marker); err != nil {
		fmt.Fprintln(os.Stderr, "fdo-answerfile:", err)
		os.Exit(1)
	}
}

func run(in, out, marker string) error {
	raw, err := os.ReadFile(in)
	if err != nil {
		return err
	}
	doc := string(raw)
	if HasAdminPassword(doc) {
		if err := os.WriteFile(out, raw, 0o600); err != nil {
			return err
		}
		fmt.Println("mode=password (answer file sets AdministratorPassword; demo only)")
		return nil
	}
	pw, err := RandomPassword()
	if err != nil {
		return err
	}
	staged, err := InsertAdminPassword(doc, pw)
	if err != nil {
		return err
	}
	if err := os.WriteFile(out, []byte(staged), 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(marker, []byte("answer file had no AdministratorPassword\r\n"), 0o600); err != nil {
		return err
	}
	fmt.Println("mode=ssh-only (random Administrator password added for setup; sshd will be key-only)")
	return nil
}
