package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"time"
	"unicode/utf8"
)

func itoa(n int) string     { return strconv.Itoa(n) }
func i64toa(n int64) string { return strconv.FormatInt(n, 10) }

// nowSec returns the current time as float epoch seconds, matching
// Python's time.time().
func nowSec() float64 {
	return float64(time.Now().UnixNano()) / 1e9
}

// utcStamp formats an epoch-seconds value the same way Python does:
// time.strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(t)) — UTC, second precision.
func utcStamp(sec float64) string {
	return time.Unix(int64(sec), 0).UTC().Format("2006-01-02T15:04:05Z")
}

// tokenURLSafe mirrors secrets.token_urlsafe(n): n bytes of CSPRNG entropy
// encoded as URL-safe base64 without padding.
func tokenURLSafe(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand failure is non-recoverable; panic like Python would
		// raise. In practice this never happens on a healthy host.
		panic("crypto/rand failed: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(buf)
}

// jsonBytes mirrors json.dumps(value, ensure_ascii=False).encode("utf-8").
// Crucially it disables Go's default HTML escaping so '<', '>', '&' survive
// verbatim, matching CPython's json output.
func jsonBytes(v any) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		// The values we marshal are always plain maps/structs; an error
		// here is a programming bug.
		panic("json encode failed: " + err.Error())
	}
	// Encoder.Encode appends a trailing newline; json.dumps does not.
	return bytes.TrimRight(buf.Bytes(), "\n")
}

// jsonError is the canonical {"error": "..."} body shape.
func jsonError(msg string) []byte {
	return jsonBytes(map[string]any{"error": msg})
}

// sanitizeUTF8 mirrors Python's payload.decode("utf-8", "replace") on the text
// frame forwarding path: invalid byte sequences become U+FFFD so the relay
// never emits a malformed UTF-8 text frame. Valid input is returned untouched
// (no allocation), which is the common case for the JSON the agent/client send.
func sanitizeUTF8(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	return bytes.ToValidUTF8(b, []byte("�"))
}
