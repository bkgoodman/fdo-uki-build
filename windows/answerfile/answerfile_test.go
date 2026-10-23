// SPDX-FileCopyrightText: (C) 2026 Dell Technologies, All Rights Reserved
// SPDX-License-Identifier: Apache-2.0
// Author: Brad Goodman

package main

import (
	"encoding/xml"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const head = `<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>fdo-win-test</ComputerName>
    </component>
  </settings>
`

func wellFormed(t *testing.T, doc string) {
	t.Helper()
	d := xml.NewDecoder(strings.NewReader(doc))
	for {
		if _, err := d.Token(); err == io.EOF {
			return
		} else if err != nil {
			t.Fatalf("not well-formed: %v\n%s", err, doc)
		}
	}
}

// adminPwPass returns the pass the AdministratorPassword ended up in.
func adminPwPass(t *testing.T, doc string) string {
	t.Helper()
	i := strings.Index(doc, "<AdministratorPassword>")
	if i < 0 {
		t.Fatalf("no AdministratorPassword:\n%s", doc)
	}
	m := regexp.MustCompile(`<settings pass="([^"]+)">`).FindAllStringSubmatchIndex(doc[:i], -1)
	return doc[m[len(m)-1][2]:m[len(m)-1][3]]
}

func TestHasAdminPassword(t *testing.T) {
	with := head + `<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><UserAccounts><AdministratorPassword><Value>x</Value></AdministratorPassword></UserAccounts></component></settings></unattend>`
	if !HasAdminPassword(with) {
		t.Error("password present but not detected")
	}
	commented := head + `<!-- <AdministratorPassword><Value>x</Value></AdministratorPassword> --></unattend>`
	if HasAdminPassword(commented) {
		t.Error("commented-out password must not count")
	}
	if HasAdminPassword(head + "</unattend>") {
		t.Error("no password, but detected")
	}
}

func TestInsertIntoExistingShellSetup(t *testing.T) {
	doc := head + `  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"><UILanguage>en-US</UILanguage></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
      <OOBE><HideEULAPage>true</HideEULAPage></OOBE>
    </component>
  </settings>
</unattend>
`
	got, err := InsertAdminPassword(doc, "Secret1Aa1!")
	if err != nil {
		t.Fatal(err)
	}
	wellFormed(t, got)
	if adminPwPass(t, got) != "oobeSystem" || strings.Count(got, "<UserAccounts>") != 1 {
		t.Fatalf("wrong placement:\n%s", got)
	}
	// inside the Shell-Setup component, after OOBE, not in International-Core
	if strings.Index(got, "<UserAccounts>") < strings.Index(got, "</OOBE>") {
		t.Fatalf("UserAccounts not in the Shell-Setup component:\n%s", got)
	}
	if !HasAdminPassword(got) || !strings.Contains(got, "<Value>Secret1Aa1!</Value>") {
		t.Fatal("password not inserted")
	}
}

func TestInsertIntoExistingUserAccounts(t *testing.T) {
	doc := head + `<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><UserAccounts><LocalAccounts/></UserAccounts></component></settings></unattend>`
	got, err := InsertAdminPassword(doc, "pw")
	if err != nil {
		t.Fatal(err)
	}
	wellFormed(t, got)
	if strings.Count(got, "<UserAccounts>") != 1 || !strings.Contains(got, "<UserAccounts><AdministratorPassword>") {
		t.Fatalf("not merged into the existing UserAccounts:\n%s", got)
	}
}

func TestInsertAddsComponentAndPass(t *testing.T) {
	noComponent := head + `<settings pass="oobeSystem"><component name="Microsoft-Windows-International-Core"/></settings></unattend>`
	got, err := InsertAdminPassword(noComponent, "pw")
	if err != nil {
		t.Fatal(err)
	}
	wellFormed(t, got)
	if adminPwPass(t, got) != "oobeSystem" || !strings.Contains(got, `name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"`) {
		t.Fatalf("component not added:\n%s", got)
	}

	noPass := head + "</unattend>\n"
	got, err = InsertAdminPassword(noPass, "pw")
	if err != nil {
		t.Fatal(err)
	}
	wellFormed(t, got)
	if adminPwPass(t, got) != "oobeSystem" {
		t.Fatalf("pass not added:\n%s", got)
	}
}

func TestInsertSpecializeShellSetupIsNotUsed(t *testing.T) {
	// The specialize pass also has a Shell-Setup component; the password
	// belongs in oobeSystem only.
	doc := head + `<settings pass="oobeSystem"></settings></unattend>`
	got, err := InsertAdminPassword(doc, "pw")
	if err != nil {
		t.Fatal(err)
	}
	if adminPwPass(t, got) != "oobeSystem" {
		t.Fatalf("password went to the wrong pass:\n%s", got)
	}
}

func TestInsertKeepsCRLF(t *testing.T) {
	doc := strings.ReplaceAll(head+`<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"></component></settings></unattend>`, "\n", "\r\n")
	got, err := InsertAdminPassword(doc, "pw")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(got, "\n") != strings.Count(got, "\r\n") {
		t.Fatal("bare LF introduced into a CRLF file")
	}
}

func TestInsertRefusals(t *testing.T) {
	with := head + `<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><UserAccounts><AdministratorPassword/></UserAccounts></component></settings></unattend>`
	if _, err := InsertAdminPassword(with, "pw"); err == nil {
		t.Error("must refuse a file that already has a password")
	}
	if _, err := InsertAdminPassword(head+"</unattend>", "a<b"); err == nil {
		t.Error("must refuse a password that needs XML escaping")
	}
	if _, err := InsertAdminPassword("<unattend>", "pw"); err == nil {
		t.Error("must refuse a truncated file")
	}
}

func TestRandomPassword(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		pw, err := RandomPassword()
		if err != nil {
			t.Fatal(err)
		}
		if len(pw) != 32 || seen[pw] {
			t.Fatalf("bad or repeated password %q", pw)
		}
		seen[pw] = true
		if strings.ContainsAny(pw, "<>&\"'") {
			t.Fatalf("password needs XML escaping: %q", pw)
		}
		classes := 0
		for _, re := range []string{`[A-Z]`, `[a-z]`, `[0-9]`, `[^A-Za-z0-9]`} {
			if regexp.MustCompile(re).MatchString(pw) {
				classes++
			}
		}
		if classes < 3 {
			t.Fatalf("password fails Windows complexity: %q", pw)
		}
	}
}

func TestRunModes(t *testing.T) {
	dir := t.TempDir()
	repoFile, err := os.ReadFile(filepath.Join("..", "..", "config", "unattend-test.xml"))
	if err != nil {
		t.Fatal(err)
	}

	// demo: the repo's test answer file has a password -> copied unchanged, no marker
	in, out, marker := filepath.Join(dir, "in.xml"), filepath.Join(dir, "out.xml"), filepath.Join(dir, "ssh-only")
	if err := os.WriteFile(in, repoFile, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := run(in, out, marker); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(out); string(got) != string(repoFile) {
		t.Error("password mode must copy the answer file unchanged")
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("password mode must not create the SSH-only marker")
	}

	// SSH-only: the same file without UserAccounts -> random password + marker
	stripped := regexp.MustCompile(`(?s)\s*<UserAccounts>.*?</UserAccounts>`).ReplaceAllString(string(repoFile), "")
	if HasAdminPassword(stripped) {
		t.Fatal("test setup: password not stripped")
	}
	if err := os.WriteFile(in, []byte(stripped), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := run(in, out, marker); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	wellFormed(t, string(got))
	if !HasAdminPassword(string(got)) || adminPwPass(t, string(got)) != "oobeSystem" {
		t.Errorf("SSH-only mode must add a password in oobeSystem:\n%s", got)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Error("SSH-only mode must create the marker")
	}
}
