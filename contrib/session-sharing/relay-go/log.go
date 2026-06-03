package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

// logMu serializes log writes so concurrent goroutines don't interleave
// partial JSON lines on stdout. Python's single event loop gave this for
// free.
var logMu sync.Mutex

// logEvent emits a single-line JSON object to stdout, matching
// log_event(event, **fields): first ts, then event, then the supplied
// fields. ensure_ascii=False parity via SetEscapeHTML(false).
//
// Go maps have no insertion order, so to keep ts/event first we build the
// object manually; the remaining fields are emitted in the order given.
func logEvent(event string, fields ...kv) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	writeJSONField(&buf, "ts", utcStamp(nowSec()), true)
	writeJSONField(&buf, "event", event, false)
	for _, f := range fields {
		writeJSONField(&buf, f.k, f.v, false)
	}
	buf.WriteByte('}')
	buf.WriteByte('\n')

	logMu.Lock()
	os.Stdout.Write(buf.Bytes())
	os.Stdout.Sync()
	logMu.Unlock()
}

// kv is a single log field. Helper constructors keep call sites terse.
type kv struct {
	k string
	v any
}

func f(k string, v any) kv { return kv{k, v} }

func writeJSONField(buf *bytes.Buffer, key string, value any, first bool) {
	if !first {
		buf.WriteByte(',')
	}
	kb, _ := marshalNoEscape(key)
	buf.Write(kb)
	buf.WriteByte(':')
	vb, err := marshalNoEscape(value)
	if err != nil {
		// Fall back to a string rendering so a bad field never drops the
		// whole log line.
		vb, _ = marshalNoEscape(fmt.Sprintf("%v", value))
	}
	buf.Write(vb)
}

func marshalNoEscape(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}
