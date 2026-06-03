package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestCleanupLoop drives the real 5s cleanup ticker once: it plants an expired
// offline session (with an expired pending upload), an expired apk grant, and a
// stale rate bucket, then asserts they're all reaped. Marked Parallel so its
// ~5s tick is hidden behind the rest of the suite's wall time.
func TestCleanupLoop(t *testing.T) {
	t.Parallel()

	cfg := newTestConfig(t)
	cfg.OfflineTTL = 1 // offline sessions expire after 1s of no contact
	st := newRelayState(cfg)
	now := nowSec()

	// Expired offline session with an expired upload that has a temp file.
	sess := newSession()
	sess.SessionID = "old"
	sess.Online = false
	sess.LastSeenAt = now - 100
	uploadPath := filepath.Join(cfg.UploadDir, "u1.bin")
	if err := os.WriteFile(uploadPath, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	sess.PendingUploads["u1"] = &PendingUpload{
		UploadID:  "u1",
		SessionID: "old",
		Path:      uploadPath,
		ExpiresAt: now - 100,
	}
	st.sessions["old"] = sess

	// Expired apk grant + stale rate bucket.
	st.apkGrants["g"] = now - 100
	st.rateLimits["1.2.3.4"] = &rateLimitBucket{windowStartedAt: now - 1000, count: 5}

	stop := make(chan struct{})
	go st.cleanupLoop(stop)
	defer close(stop)

	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		st.mu.Lock()
		_, sExists := st.sessions["old"]
		_, gExists := st.apkGrants["g"]
		_, rExists := st.rateLimits["1.2.3.4"]
		st.mu.Unlock()
		if !sExists && !gExists && !rExists {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	st.mu.Lock()
	defer st.mu.Unlock()
	if _, ok := st.sessions["old"]; ok {
		t.Error("expired offline session not removed")
	}
	if _, ok := st.apkGrants["g"]; ok {
		t.Error("expired apk grant not removed")
	}
	if _, ok := st.rateLimits["1.2.3.4"]; ok {
		t.Error("stale rate bucket not removed")
	}
	if _, err := os.Stat(uploadPath); !os.IsNotExist(err) {
		t.Errorf("expired upload temp file not removed: %v", err)
	}
	if metricValue(st, "upload_expired_total") < 1 {
		t.Errorf("upload_expired_total=%d, want >=1", metricValue(st, "upload_expired_total"))
	}
}
