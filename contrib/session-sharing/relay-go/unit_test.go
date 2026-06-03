package main

import (
	"bytes"
	"net/netip"
	"testing"
)

// ---- 14. sanitizeUTF8 ----

func TestSanitizeUTF8(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want []byte
	}{
		{"valid ascii", []byte("hello"), []byte("hello")},
		{"valid multibyte", []byte("héllo世界"), []byte("héllo世界")},
		{"empty", []byte(""), []byte("")},
		{"invalid byte", []byte{'a', 0xff, 'b'}, []byte{'a', 0xEF, 0xBF, 0xBD, 'b'}},
		{"lone continuation", []byte{0x80}, []byte{0xEF, 0xBF, 0xBD}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := sanitizeUTF8(tc.in)
			if !bytes.Equal(got, tc.want) {
				t.Errorf("sanitizeUTF8(%v)=%v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

// ---- 15. hostRequiresPublicBindAck ----

func TestHostRequiresPublicBindAck(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"localhost", false},
		{"127.0.0.1", false},
		{"::1", false},
		{"0.0.0.0", true},
		{"::", true},
		{"10.0.0.5", false},
		{"192.168.1.10", false},
		{"172.16.4.4", false},
		{"169.254.1.1", false},
		{"fe80::1", false},
		{"fc00::1", false},
		{"100.64.0.1", true}, // CGNAT: Python's is_private excludes 100.64/10, so it needs an ack.
		{"8.8.8.8", true},
		{"not-an-ip-host", true},
	}
	for _, tc := range cases {
		t.Run(tc.host, func(t *testing.T) {
			if got := hostRequiresPublicBindAck(tc.host); got != tc.want {
				t.Errorf("hostRequiresPublicBindAck(%q)=%v, want %v", tc.host, got, tc.want)
			}
		})
	}
}

// ---- 16. resolveClientIP / parseTrustedProxies ----

func TestParseTrustedProxies(t *testing.T) {
	got := parseTrustedProxies("10.0.0.0/8, 192.168.1.1 , , bogus, 2001:db8::/32")
	// Expect: 10.0.0.0/8, 192.168.1.1/32, 2001:db8::/32 (bogus dropped, blank dropped).
	if len(got) != 3 {
		t.Fatalf("got %d prefixes: %v", len(got), got)
	}
	wantStrings := map[string]bool{
		"10.0.0.0/8":     true,
		"192.168.1.1/32": true,
		"2001:db8::/32":  true,
	}
	for _, p := range got {
		if !wantStrings[p.String()] {
			t.Errorf("unexpected prefix %s", p.String())
		}
	}
}

func TestResolveClientIP(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}
	cases := []struct {
		name    string
		peer    string
		xff     string
		trusted []netip.Prefix
		want    string
	}{
		{"empty peer", "", "1.2.3.4", trusted, "unknown"},
		{"no trusted -> peer", "203.0.113.1", "1.2.3.4", nil, "203.0.113.1"},
		{"peer not trusted -> peer", "203.0.113.1", "1.2.3.4", trusted, "203.0.113.1"},
		{"peer trusted, xff first hop", "10.1.2.3", "5.6.7.8, 9.9.9.9", trusted, "5.6.7.8"},
		{"peer trusted, empty xff -> peer", "10.1.2.3", "", trusted, "10.1.2.3"},
		{"peer trusted, bad xff -> peer", "10.1.2.3", "garbage", trusted, "10.1.2.3"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveClientIP(tc.peer, tc.xff, tc.trusted); got != tc.want {
				t.Errorf("resolveClientIP(%q,%q)=%q, want %q", tc.peer, tc.xff, got, tc.want)
			}
		})
	}
}

// ---- appendBacklog dedup / trimming ----

func TestAppendBacklogEssentialDedup(t *testing.T) {
	sess := newSession()
	// Two hello frames: only the latest must remain.
	sess.appendBacklog(opcodeText, []byte(`{"type":"hello","v":1}`))
	sess.appendBacklog(opcodeText, []byte(`{"type":"hello","v":2}`))
	sess.appendBacklog(opcodeText, []byte(`{"type":"appearance","c":"dark"}`))

	helloCount := 0
	var lastHello string
	for _, e := range sess.backlog {
		if t2, ok := essentialMetadataType(e.opcode, e.payload); ok && t2 == "hello" {
			helloCount++
			lastHello = string(e.payload)
		}
	}
	if helloCount != 1 {
		t.Fatalf("expected 1 hello after dedup, got %d", helloCount)
	}
	if lastHello != `{"type":"hello","v":2}` {
		t.Errorf("kept hello=%q, want the latest v:2", lastHello)
	}
}

func TestAppendBacklogScreenTrim(t *testing.T) {
	sess := newSession()
	sess.appendBacklog(opcodeText, []byte(`{"type":"hello","cols":80}`))
	sess.appendBacklog(opcodeText, []byte("plain-output-1"))
	sess.appendBacklog(opcodeText, []byte("plain-output-2"))
	// A screen snapshot drops earlier frames except essential metadata.
	sess.appendBacklog(opcodeText, []byte(`{"type":"screen","d":"x"}`))

	hasHello := false
	hasPlain := false
	hasScreen := false
	for _, e := range sess.backlog {
		switch {
		case isEssentialMetadata(e.payload):
			hasHello = true
		case isScreenSnapshot(e.payload):
			hasScreen = true
		case string(e.payload) == "plain-output-1" || string(e.payload) == "plain-output-2":
			hasPlain = true
		}
	}
	if !hasHello {
		t.Errorf("hello should survive screen trim")
	}
	if hasPlain {
		t.Errorf("plain output before screen should be trimmed")
	}
	if !hasScreen {
		t.Errorf("screen snapshot should be present")
	}
}

func TestAppendBacklogIgnoresEmptyAndControl(t *testing.T) {
	sess := newSession()
	sess.appendBacklog(opcodeText, []byte("")) // empty -> ignored
	sess.appendBacklog(8, []byte("close"))     // non text/binary opcode -> ignored
	if len(sess.backlog) != 0 {
		t.Errorf("backlog should be empty, got %d entries", len(sess.backlog))
	}
	sess.appendBacklog(opcodeBinary, []byte{0x01, 0x02})
	if len(sess.backlog) != 1 || sess.backlogSize != 2 {
		t.Errorf("expected 1 frame size 2, got %d frames size %d", len(sess.backlog), sess.backlogSize)
	}
}
