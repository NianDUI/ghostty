package main

import (
	"os"
	"testing"
)

func TestEnvHelpers(t *testing.T) {
	if envStr("CFG_MISSING_STR", "def") != "def" {
		t.Error("envStr missing -> default")
	}
	t.Setenv("CFG_STR", "hello")
	if envStr("CFG_STR", "def") != "hello" {
		t.Error("envStr set -> value")
	}

	if envInt("CFG_MISSING_INT", 7) != 7 {
		t.Error("envInt missing -> default")
	}
	t.Setenv("CFG_INT", "42")
	if envInt("CFG_INT", 0) != 42 {
		t.Error("envInt set -> value")
	}
	t.Setenv("CFG_INT_BAD", "xx")
	if envInt("CFG_INT_BAD", 7) != 7 {
		t.Error("envInt invalid -> default")
	}

	if envFloat("CFG_MISSING_F", 1.25) != 1.25 {
		t.Error("envFloat missing -> default")
	}
	t.Setenv("CFG_F", "2.5")
	if envFloat("CFG_F", 0) != 2.5 {
		t.Error("envFloat set -> value")
	}

	t.Setenv("CFG_BOOL_ON", "yes")
	if !envBool("CFG_BOOL_ON", false) {
		t.Error("envBool yes -> true")
	}
	t.Setenv("CFG_BOOL_OFF", "off")
	if envBool("CFG_BOOL_OFF", true) {
		t.Error("envBool off -> false")
	}
	if !envBool("CFG_MISSING_BOOL", true) {
		t.Error("envBool missing -> default")
	}
}

func TestLoadAllowedUserTokens(t *testing.T) {
	// Inline list: trimmed, blanks skipped.
	t.Setenv("GHOSTTY_RELAY_USER_TOKENS", "a, b ,, c")
	t.Setenv("GHOSTTY_RELAY_USER_TOKENS_FILE", "")
	toks := loadAllowedUserTokens()
	if len(toks) != 3 {
		t.Fatalf("len=%d, want 3 (%v)", len(toks), toks)
	}
	for _, w := range []string{"a", "b", "c"} {
		if _, ok := toks[w]; !ok {
			t.Errorf("missing token %q", w)
		}
	}

	// File: one per line, '#' comments and blanks skipped.
	dir := t.TempDir()
	file := dir + "/tokens.txt"
	if err := os.WriteFile(file, []byte("x\n# comment\n\n y \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GHOSTTY_RELAY_USER_TOKENS", "")
	t.Setenv("GHOSTTY_RELAY_USER_TOKENS_FILE", file)
	toks = loadAllowedUserTokens()
	if _, ok := toks["x"]; !ok {
		t.Error("file token x missing")
	}
	if _, ok := toks["y"]; !ok {
		t.Error("file token y (trimmed) missing")
	}
	if _, ok := toks["# comment"]; ok {
		t.Error("comment line should be skipped")
	}
}
