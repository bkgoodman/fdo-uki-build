// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"regexp"
	"strings"
)

// The Windows answer file (unattend.xml) delivered by the owner decides how
// the local Administrator account is set up:
//
//   - with <AdministratorPassword> (demo): used as is. A plaintext password
//     in a delivered file is not recommended outside demos.
//   - without it (SSH-only): Windows Server's first-boot setup would stop
//     and ask for one, so a random password nobody ever sees is added here
//     (only to get through setup; SetupComplete.cmd deletes the answer file)
//     and the caller marks the install SSH-only, which makes sshd key-only.
//
// The account itself stays enabled: Windows refuses SSH key logins to a
// disabled account too.

var (
	reComment      = regexp.MustCompile(`(?s)<!--.*?-->`)
	reAdminPw      = regexp.MustCompile(`<AdministratorPassword\b`)
	reOOBEPass     = regexp.MustCompile(`<settings\s+pass\s*=\s*["']oobeSystem["']\s*>`)
	reShellSetup   = regexp.MustCompile(`<component\b[^>]*\bname\s*=\s*["']Microsoft-Windows-Shell-Setup["'][^>]*>`)
	reUserAccounts = regexp.MustCompile(`<UserAccounts\s*>`)
)

// HasAdminPassword reports whether the answer file sets the local
// Administrator password (XML comments are ignored).
func HasAdminPassword(doc string) bool {
	return reAdminPw.MatchString(reComment.ReplaceAllString(doc, ""))
}

// InsertAdminPassword returns doc with an <AdministratorPassword> for pw in
// the oobeSystem pass, adding the UserAccounts element, the Shell-Setup
// component or the pass itself as needed. The line ending of doc is kept.
func InsertAdminPassword(doc, pw string) (string, error) {
	if HasAdminPassword(doc) {
		return "", errors.New("answer file already sets AdministratorPassword")
	}
	if strings.ContainsAny(pw, "<>&\"'") {
		return "", errors.New("password must not need XML escaping")
	}
	nl := "\n"
	if strings.Contains(doc, "\r\n") {
		nl = "\r\n"
	}
	adminPw := "<AdministratorPassword><Value>" + pw + "</Value><PlainText>true</PlainText></AdministratorPassword>"
	userAccounts := "<UserAccounts>" + adminPw + "</UserAccounts>"
	component := `<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" ` +
		`publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">` + userAccounts + `</component>`

	pass := reOOBEPass.FindStringIndex(doc)
	if pass == nil {
		end := strings.LastIndex(doc, "</unattend>")
		if end < 0 {
			return "", errors.New("no </unattend> element")
		}
		return doc[:end] + `<settings pass="oobeSystem">` + component + `</settings>` + nl + doc[end:], nil
	}
	passEnd := strings.Index(doc[pass[1]:], "</settings>")
	if passEnd < 0 {
		return "", errors.New("oobeSystem pass is not closed")
	}
	passEnd += pass[1]
	section := doc[pass[1]:passEnd]

	comp := reShellSetup.FindStringIndex(section)
	if comp == nil {
		return doc[:passEnd] + component + nl + doc[passEnd:], nil
	}
	compStart := pass[1] + comp[1]
	compEnd := strings.Index(doc[compStart:passEnd], "</component>")
	if compEnd < 0 {
		return "", errors.New("Shell-Setup component is not closed")
	}
	compEnd += compStart
	if ua := reUserAccounts.FindStringIndex(doc[compStart:compEnd]); ua != nil {
		at := compStart + ua[1]
		return doc[:at] + adminPw + doc[at:], nil
	}
	return doc[:compEnd] + userAccounts + nl + doc[compEnd:], nil
}

// RandomPassword returns a 32-character password from the system RNG
// (BCryptGenRandom on Windows) that meets Windows' default complexity rule
// (three of: upper, lower, digit, symbol) whatever the random part is.
func RandomPassword() (string, error) {
	b := make([]byte, 21)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	// RawURLEncoding: [A-Za-z0-9_-], nothing that needs XML escaping.
	return base64.RawURLEncoding.EncodeToString(b) + "Aa1!", nil
}
