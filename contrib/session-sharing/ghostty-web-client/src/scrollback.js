// State machine that backs Phase 2b lazy scrollback.
//
// `ghostty-web` doesn't expose a "prepend rows above existing scrollback"
// entry point, so the browser fakes it by remembering everything it ever
// received and replaying the lot through `term.reset() + term.write(...)`
// every time we want to insert older history. The cost is a flash on
// each replay; the win is no fork of `coder/ghostty-web`.
//
// This module is deliberately framework-free so it round-trips through
// `node --test`. The wiring (terminal calls, socket sends, scroll
// listeners) lives in main.js.

// Snapshots from the agent always start with `\x1b[2J\x1b[H` (clear +
// home). When we replay we want exactly one such prefix at the very
// front, so we strip it from the snapshot body and add a single
// canonical prefix on every replay.
export const SNAPSHOT_PREFIX = new Uint8Array([
  0x1b, 0x5b, 0x32, 0x4a, 0x1b, 0x5b, 0x48,
]);

// Hard cap on the live byte buffer between snapshots. Without it a
// noisy producer (`cat /var/log/system.log`, `npm install`) would
// grow the JS heap unboundedly — every replay would also have to
// rewrite the entire history. 256 KiB is roughly 4× the relay's
// per-session backlog cap, enough to comfortably cover the gap
// between two snapshots on a busy session without becoming a
// long-tail memory leak.
const LIVE_BUFFER_BYTES_CAP = 256 * 1024;

function startsWithPrefix(bytes, prefix) {
  if (!bytes || bytes.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i += 1) {
    if (bytes[i] !== prefix[i]) return false;
  }
  return true;
}

function stripSnapshotPrefix(bytes) {
  if (startsWithPrefix(bytes, SNAPSHOT_PREFIX)) {
    return bytes.subarray(SNAPSHOT_PREFIX.length);
  }
  return bytes;
}

function concatBytes(chunks) {
  let total = 0;
  for (const chunk of chunks) total += chunk.length;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

function countLines(bytes) {
  if (!bytes || bytes.length === 0) return 0;
  let lines = 1;
  for (let i = 1; i < bytes.length; i += 1) {
    if (bytes[i - 1] === 0x0d && bytes[i] === 0x0a) lines += 1;
  }
  // A trailing \r\n contributes a final empty line that nothing
  // actually rendered to; subtract it to mirror the agent's view.
  if (
    bytes.length >= 2 &&
    bytes[bytes.length - 2] === 0x0d &&
    bytes[bytes.length - 1] === 0x0a
  ) {
    lines -= 1;
  }
  return lines;
}

export function createReplayBuffer() {
  // `olderChunks` holds VT bytes that were fetched lazily, oldest
  // chunk first. Each chunk is the raw VT body of one fetch response
  // (without the snapshot prefix).
  let olderChunks = [];
  let snapshotBody = new Uint8Array(0); // snapshot decoded WITHOUT prefix
  let liveBuffer = new Uint8Array(0); // bytes since the last snapshot
  let snapshotLineCount = 0;
  let olderHistoryRows = 0;
  let agentTotal = null; // total reported by latest scrollback frame
  let inflight = false;

  return {
    onScreen(decodedBytes) {
      // A fresh snapshot tears down the entire replay state — anything
      // older we had no longer corresponds to what the agent thinks of
      // as the screen.
      snapshotBody = stripSnapshotPrefix(decodedBytes);
      olderChunks = [];
      liveBuffer = new Uint8Array(0);
      olderHistoryRows = 0;
      agentTotal = null;
      inflight = false;
      snapshotLineCount = countLines(snapshotBody);
    },
    onLive(bytes) {
      // Append; we replay the full live buffer on each future fetch
      // so older content lands in the correct relative position. Cap
      // the buffer so a long noisy session doesn't leak memory or
      // make every replay drag the full session through term.write.
      // Trim from the front: the byte at the cut may land mid-VT
      // sequence, but the next live byte fixes that on its own and
      // the snapshot replay always restarts from a clean
      // `\x1b[2J\x1b[H`.
      const appended = concatBytes([liveBuffer, bytes]);
      liveBuffer =
        appended.length > LIVE_BUFFER_BYTES_CAP
          ? appended.subarray(appended.length - LIVE_BUFFER_BYTES_CAP)
          : appended;
    },
    onScrollback(decodedBytes, { count, total } = {}) {
      // The newest fetch comes from BEFORE our oldest known row, so
      // its rows go at the front of the older chunks list. We also
      // append a `\r\n` if the agent's payload didn't end with one,
      // otherwise it'd run into the snapshot's first line.
      let chunk = decodedBytes;
      if (chunk.length > 0) {
        const lastTwo =
          chunk.length >= 2 ? chunk.subarray(chunk.length - 2) : null;
        const endsWithCRLF =
          lastTwo && lastTwo[0] === 0x0d && lastTwo[1] === 0x0a;
        if (!endsWithCRLF) {
          chunk = concatBytes([chunk, new Uint8Array([0x0d, 0x0a])]);
        }
      }
      olderChunks = [chunk, ...olderChunks];
      if (Number.isInteger(count) && count >= 0) {
        olderHistoryRows += count;
      }
      if (Number.isInteger(total) && total >= 0) {
        agentTotal = total;
      }
      inflight = false;
    },
    fetchStarted() {
      inflight = true;
    },
    fetchFailed() {
      inflight = false;
    },
    isFetchInFlight() {
      return inflight;
    },
    /// Number of history rows the browser already holds across the
    /// snapshot + every prior fetch. The next `fetch_scrollback`
    /// request uses this as `before`.
    coveredHistoryRows(hostRows) {
      const inSnapshot = Math.max(
        0,
        snapshotLineCount - Math.max(1, hostRows || 1),
      );
      return inSnapshot + olderHistoryRows;
    },
    /// True once the agent reported a `total` and the browser has
    /// caught up to it; further fetches would just return empty.
    hasReachedTop(hostRows) {
      if (agentTotal === null) return false;
      return this.coveredHistoryRows(hostRows) >= agentTotal;
    },
    /// Build the bytes that should be written to a fresh terminal
    /// (after `terminal.reset()`) to reproduce the host's full known
    /// state: prefix + older history + snapshot body + live deltas.
    buildReplayBytes() {
      return concatBytes([
        SNAPSHOT_PREFIX,
        ...olderChunks,
        snapshotBody,
        liveBuffer,
      ]);
    },
    /// Internal accessors used by tests; main.js doesn't need them.
    _state() {
      return {
        olderChunks: olderChunks.map((c) => Array.from(c)),
        snapshotBody: Array.from(snapshotBody),
        liveBuffer: Array.from(liveBuffer),
        snapshotLineCount,
        olderHistoryRows,
        agentTotal,
        inflight,
      };
    },
  };
}
