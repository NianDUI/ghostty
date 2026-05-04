import { test } from "node:test";
import assert from "node:assert/strict";
import { createReplayBuffer, SNAPSHOT_PREFIX } from "../src/scrollback.js";

const PREFIX = SNAPSHOT_PREFIX;

function bytes(text) {
  return new TextEncoder().encode(text);
}

function decode(bytesValue) {
  return new TextDecoder().decode(bytesValue);
}

function snapshotBytes(body) {
  const bodyBytes = bytes(body);
  const out = new Uint8Array(PREFIX.length + bodyBytes.length);
  out.set(PREFIX, 0);
  out.set(bodyBytes, PREFIX.length);
  return out;
}

test("buildReplayBytes always emits exactly one snapshot prefix", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("hello\r\nworld"));
  const text = decode(buf.buildReplayBytes());
  assert.equal(text.indexOf("\u001b[2J\u001b[H"), 0);
  // No second clear-and-home anywhere else in the replay.
  assert.equal(text.indexOf("\u001b[2J\u001b[H", 1), -1);
  assert.ok(text.endsWith("hello\r\nworld"));
});

test("onLive bytes are appended after the snapshot body", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("snap"));
  buf.onLive(bytes("live1"));
  buf.onLive(bytes("live2"));
  assert.ok(decode(buf.buildReplayBytes()).endsWith("snaplive1live2"));
});

test("onScrollback prepends older chunks before the snapshot body", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("snap"));
  buf.onLive(bytes("live"));
  buf.onScrollback(bytes("older"), { count: 1, total: 99 });
  const text = decode(buf.buildReplayBytes());
  // Layout: prefix + older chunk (with auto-CRLF) + snapshot body + live.
  const afterPrefix = text.slice(7);
  assert.equal(afterPrefix, "older\r\nsnaplive");
});

test("onScrollback chains: oldest goes furthest from the snapshot", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("snap"));
  buf.onScrollback(bytes("near"), { count: 1, total: 9 });
  buf.onScrollback(bytes("far"), { count: 1, total: 9 });
  const text = decode(buf.buildReplayBytes());
  const afterPrefix = text.slice(7);
  // The second fetch is older than the first, so it must appear
  // furthest from the snapshot body (rendered first).
  assert.equal(afterPrefix, "far\r\nnear\r\nsnap");
});

test("isFetchInFlight gates concurrent fetches", () => {
  const buf = createReplayBuffer();
  assert.equal(buf.isFetchInFlight(), false);
  buf.fetchStarted();
  assert.equal(buf.isFetchInFlight(), true);
  buf.onScrollback(bytes("x"), { count: 1, total: 5 });
  assert.equal(buf.isFetchInFlight(), false);
});

test("hasReachedTop flips once covered rows match the agent total", () => {
  const buf = createReplayBuffer();
  // Snapshot has 25 lines (24 viewport + 1 history line).
  const body = "snap\r\n".repeat(24) + "snapline";
  buf.onScreen(snapshotBytes(body));
  // hostRows=24 means 1 history row sits in the snapshot already.
  assert.equal(buf.coveredHistoryRows(24), 1);
  assert.equal(buf.hasReachedTop(24), false);
  buf.onScrollback(bytes("older"), { count: 4, total: 5 });
  assert.equal(buf.coveredHistoryRows(24), 5);
  assert.equal(buf.hasReachedTop(24), true);
});

test("onLive caps the buffer to keep memory bounded on a noisy session", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("snap"));
  // Push more than the soft cap (~256 KiB) so the trim has to fire.
  // The exact threshold isn't part of the public API; we just need
  // the buffer to refuse to grow past a reasonable ceiling.
  const oneKb = new Uint8Array(1024);
  for (let i = 0; i < 320; i += 1) buf.onLive(oneKb);
  const liveLen = buf._state().liveBuffer.length;
  assert.ok(
    liveLen <= 256 * 1024,
    `live buffer should be trimmed (got ${liveLen} bytes)`,
  );
  assert.ok(
    liveLen >= 256 * 1024 - 1024,
    `live buffer should keep close to the cap (got ${liveLen} bytes)`,
  );
});

test("a fresh onScreen tears down older chunks and live buffer", () => {
  const buf = createReplayBuffer();
  buf.onScreen(snapshotBytes("first"));
  buf.onLive(bytes("livefirst"));
  buf.onScrollback(bytes("older"), { count: 1, total: 9 });
  buf.onScreen(snapshotBytes("second"));
  const text = decode(buf.buildReplayBytes());
  assert.equal(text.slice(7), "second");
});
