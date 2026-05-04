import { test } from "node:test";
import assert from "node:assert/strict";
import { createCoalescedScroll } from "../src/scroll.js";

test("createCoalescedScroll defers work to the scheduler", () => {
  let scheduledCb = null;
  let calls = 0;
  const request = createCoalescedScroll(
    (cb) => {
      scheduledCb = cb;
    },
    () => {
      calls += 1;
    },
  );
  request();
  assert.equal(calls, 0, "scroll should not run synchronously");
  scheduledCb();
  assert.equal(calls, 1);
});

test("createCoalescedScroll coalesces back-to-back requests into one tick", () => {
  let scheduledCb = null;
  let scheduleCalls = 0;
  let scrollCalls = 0;
  const request = createCoalescedScroll(
    (cb) => {
      scheduleCalls += 1;
      scheduledCb = cb;
    },
    () => {
      scrollCalls += 1;
    },
  );
  request();
  request();
  request();
  request();
  assert.equal(scheduleCalls, 1, "only the first request schedules a tick");
  scheduledCb();
  assert.equal(scrollCalls, 1, "queued requests fold into a single scroll");
});

test("createCoalescedScroll allows another tick after the previous one fires", () => {
  let scheduledCb = null;
  let scheduleCalls = 0;
  let scrollCalls = 0;
  const request = createCoalescedScroll(
    (cb) => {
      scheduleCalls += 1;
      scheduledCb = cb;
    },
    () => {
      scrollCalls += 1;
    },
  );
  request();
  scheduledCb();
  request();
  scheduledCb();
  assert.equal(scheduleCalls, 2);
  assert.equal(scrollCalls, 2);
});

test("createCoalescedScroll requests issued from inside the scroll callback get a fresh tick", () => {
  // Mirrors a real-world re-entrancy hazard: the scroll callback might
  // emit a resize that triggers another request. We need the new request
  // to schedule again, not be silently dropped.
  let scheduledCb = null;
  let scheduleCalls = 0;
  let scrollCalls = 0;
  const scrollFn = () => {
    scrollCalls += 1;
    if (scrollCalls === 1) {
      // Pretend something inside the scroll asked for another scroll.
      request();
    }
  };
  const request = createCoalescedScroll((cb) => {
    scheduleCalls += 1;
    scheduledCb = cb;
  }, scrollFn);
  request();
  scheduledCb();
  assert.equal(scrollCalls, 1);
  assert.equal(scheduleCalls, 2, "re-entrant request should schedule again");
  scheduledCb();
  assert.equal(scrollCalls, 2);
});
