package main

import (
	"crypto/sha256"
	"encoding/json"
	"hash"
	"sync"
)

// WebSocket opcodes. These intentionally equal gorilla's TextMessage(1) /
// BinaryMessage(2), so the same constant works for both backlog tagging and
// the gorilla read/write API.
const (
	opcodeText   = 1
	opcodeBinary = 2
)

// Upload-related limits (mirror server.py module constants).
const (
	uploadNameMaxLength = 200 // bytes
	nameUpdateMaxLength = 256 // chars (runes)
)

// uploadForbiddenNameChars: sentinels rejected anywhere in a filename.
var uploadForbiddenNameChars = map[rune]struct{}{
	'/': {}, '\\': {}, '\x00': {}, '\r': {}, '\n': {},
}

// essentialBacklogTypes: text-frame types whose value to a fresh client
// outlasts a screen checkpoint (hello carries cols/rows, appearance carries
// colours/font-size).
var essentialBacklogTypes = map[string]struct{}{
	"hello": {}, "appearance": {},
}

// backlogFrame is one (opcode, payload) entry in a session's replay buffer.
type backlogFrame struct {
	opcode  int
	payload []byte
}

// queuedFrame is one item in a client's send queue. drop=true is the
// slow-consumer sentinel (Python's None).
type queuedFrame struct {
	opcode  int
	payload []byte
	drop    bool
}

// clientChannel is a per-client send buffer with a byte cap (PORT-SPEC §4).
//
// The queue is unbounded, like Python's asyncio.Queue(): back-pressure comes
// solely from the byte cap (client_send_buffer_bytes), which marks the channel
// dropped once exceeded. We use a mutex + sync.Cond + slice instead of a Go
// channel because channels can't be unbounded; an 8192-slot channel would drop
// frames earlier than Python under a flood of tiny frames.
type clientChannel struct {
	conn *wsConn

	mu          sync.Mutex
	cond        *sync.Cond
	items       []queuedFrame
	closed      bool
	queuedBytes int
	maxBytes    int
	dropped     bool
}

func newClientChannel(conn *wsConn, maxBytes int) *clientChannel {
	c := &clientChannel{conn: conn, maxBytes: maxBytes}
	c.cond = sync.NewCond(&c.mu)
	return c
}

// tryEnqueue mirrors ClientChannel.try_enqueue. Returns false (and marks the
// channel dropped, enqueuing the slow-consumer sentinel) when the byte cap is
// exceeded.
func (c *clientChannel) tryEnqueue(opcode int, payload []byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dropped || c.closed {
		return false
	}
	if c.maxBytes > 0 && c.queuedBytes+len(payload) > c.maxBytes {
		c.dropped = true
		c.items = append(c.items, queuedFrame{drop: true})
		c.cond.Signal()
		return false
	}
	c.queuedBytes += len(payload)
	c.items = append(c.items, queuedFrame{opcode: opcode, payload: payload})
	c.cond.Signal()
	return true
}

// dequeue blocks until an item is available or the channel is shut down. ok is
// false once the channel has been shut down and fully drained.
func (c *clientChannel) dequeue() (item queuedFrame, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.items) == 0 && !c.closed {
		c.cond.Wait()
	}
	if len(c.items) == 0 {
		return queuedFrame{}, false
	}
	item = c.items[0]
	c.items = c.items[1:]
	return item, true
}

// shutdown wakes the sender so it can exit once the client WS closes.
func (c *clientChannel) shutdown() {
	c.mu.Lock()
	c.closed = true
	c.cond.Broadcast()
	c.mu.Unlock()
}

func (c *clientChannel) drainBytes(n int) {
	c.mu.Lock()
	c.queuedBytes -= n
	if c.queuedBytes < 0 {
		c.queuedBytes = 0
	}
	c.mu.Unlock()
}

// PendingUpload mirrors the dataclass of the same name (PORT-SPEC §4).
type PendingUpload struct {
	UploadID       string
	SessionID      string
	Name           string
	Size           int64
	SHA256         string // declared (lowercase hex); "" if not provided
	HasSHA256      bool
	PullToken      string
	Path           string
	CreatedAt      float64
	ExpiresAt      float64
	Received       int64
	SHA256Observed string
	Delivered      bool
	Uploading      bool
	hasherImpl     hash.Hash
}

// hasher lazily creates the rolling sha256, idempotent so PATCH chunks
// accumulate into one digest.
func (u *PendingUpload) hasher() hash.Hash {
	if u.hasherImpl == nil {
		u.hasherImpl = sha256.New()
	}
	return u.hasherImpl
}

// Session mirrors the Session dataclass (PORT-SPEC §4).
type Session struct {
	SessionID   string
	Name        string
	UserToken   string
	AgentToken  string
	ClientToken string
	ExpiresAt   float64
	Online      bool
	LastSeenAt  float64
	AgentWriter *wsConn
	Clients     map[*wsConn]*clientChannel

	backlog     []backlogFrame
	backlogSize int

	PendingUploads            map[string]*PendingUpload
	UploadedBytesTotal        int64
	PendingReadyNotifications []string

	// disconnectGrace, when non-nil, cancels the in-flight grace timer that
	// keeps clients attached after the agent's WS drops.
	disconnectGrace *graceTimer
}

func newSession() *Session {
	return &Session{
		Clients:        map[*wsConn]*clientChannel{},
		PendingUploads: map[string]*PendingUpload{},
		LastSeenAt:     nowSec(),
	}
}

// graceTimer wraps a cancelable agent-disconnect grace task.
type graceTimer struct {
	cancel chan struct{}
	done   chan struct{}
	once   sync.Once
}

func (g *graceTimer) Cancel() {
	g.once.Do(func() { close(g.cancel) })
}

// ---- backlog logic (PORT-SPEC §22) ----
// Callers must hold state.mu when invoking appendBacklog / snapshotBacklog.

// appendBacklog mirrors Session.append_backlog, including essential-metadata
// dedup and screen-snapshot trimming.
func (s *Session) appendBacklog(opcode int, payload []byte) {
	if (opcode != opcodeText && opcode != opcodeBinary) || len(payload) == 0 {
		return
	}

	// Essential metadata dedup: keep only the latest value of each type.
	if newType, ok := essentialMetadataType(opcode, payload); ok {
		kept := s.backlog[:0:0]
		keptSize := 0
		for _, e := range s.backlog {
			if t, ok2 := essentialMetadataType(e.opcode, e.payload); ok2 && t == newType {
				continue
			}
			kept = append(kept, e)
			keptSize += len(e.payload)
		}
		s.backlog = kept
		s.backlogSize = keptSize
	}

	// Screen snapshot: drop everything before it, except essential metadata.
	if opcode == opcodeText && isScreenSnapshot(payload) {
		preserved := make([]backlogFrame, 0, len(s.backlog))
		preservedSize := 0
		for _, e := range s.backlog {
			if e.opcode == opcodeText && isEssentialMetadata(e.payload) {
				preserved = append(preserved, e)
				preservedSize += len(e.payload)
			}
		}
		s.backlog = preserved
		s.backlogSize = preservedSize
	}

	cp := make([]byte, len(payload))
	copy(cp, payload)
	s.backlog = append(s.backlog, backlogFrame{opcode: opcode, payload: cp})
	s.backlogSize += len(cp)

	for s.backlogSize > sessionBacklogLimit || len(s.backlog) > sessionBacklogFrameLimit {
		stale := s.backlog[0]
		s.backlog = s.backlog[1:]
		if stale.opcode == opcodeText || stale.opcode == opcodeBinary {
			s.backlogSize -= len(stale.payload)
		}
	}
}

// snapshotBacklog returns a copy of the current backlog for replay. Caller
// must hold state.mu.
func (s *Session) snapshotBacklog() []backlogFrame {
	out := make([]backlogFrame, len(s.backlog))
	copy(out, s.backlog)
	return out
}

func isScreenSnapshot(payload []byte) bool {
	if len(payload) == 0 {
		return false
	}
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return false
	}
	t, _ := m["type"].(string)
	return t == "screen"
}

// essentialMetadataType returns (type, true) for a text-opcode payload whose
// JSON type is hello/appearance.
func essentialMetadataType(opcode int, payload []byte) (string, bool) {
	if opcode != opcodeText || len(payload) == 0 {
		return "", false
	}
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return "", false
	}
	t, ok := m["type"].(string)
	if !ok {
		return "", false
	}
	if _, isEssential := essentialBacklogTypes[t]; isEssential {
		return t, true
	}
	return "", false
}

func isEssentialMetadata(payload []byte) bool {
	_, ok := essentialMetadataType(opcodeText, payload)
	return ok
}
