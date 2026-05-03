import { test } from "node:test";
import assert from "node:assert/strict";
import { redactSensitiveText, redactErrorMessage } from "../src/redaction.js";

test("redactSensitiveText replaces Bearer tokens", () => {
  assert.equal(
    redactSensitiveText("Authorization: Bearer abc-123_def"),
    "Authorization: Bearer [REDACTED]",
  );
});

test("redactSensitiveText scrubs ?token= query params", () => {
  assert.equal(
    redactSensitiveText("ws://r/ws/client?id=foo&token=secretval"),
    "ws://r/ws/client?id=foo&token=[REDACTED]",
  );
});

test("redactSensitiveText scrubs client_token and agent_token query params", () => {
  assert.equal(
    redactSensitiveText("/api?client_token=AAAA&agent_token=BBBB&other=keep"),
    "/api?client_token=[REDACTED]&agent_token=[REDACTED]&other=keep",
  );
});

test("redactSensitiveText leaves non-sensitive text unchanged", () => {
  const input = "ws://r/ws/client?id=foo";
  assert.equal(redactSensitiveText(input), input);
});

test("redactSensitiveText passes non-string values through", () => {
  assert.equal(redactSensitiveText(null), null);
  assert.equal(redactSensitiveText(undefined), undefined);
  assert.equal(redactSensitiveText(42), 42);
});

test("redactErrorMessage extracts and redacts the message field", () => {
  const error = new Error("Failed to fetch ?token=secret&id=1");
  assert.equal(
    redactErrorMessage(error),
    "Failed to fetch ?token=[REDACTED]&id=1",
  );
});

test("redactErrorMessage handles null and undefined", () => {
  assert.equal(redactErrorMessage(null), "");
  assert.equal(redactErrorMessage(undefined), "");
});

test("redactErrorMessage handles plain strings", () => {
  assert.equal(
    redactErrorMessage("Bearer XXX failed"),
    "Bearer [REDACTED] failed",
  );
});

test("redactErrorMessage handles objects without message via String() coercion", () => {
  const obj = { toString: () => "boom Bearer X1Y2Z" };
  assert.equal(redactErrorMessage(obj), "boom Bearer [REDACTED]");
});
