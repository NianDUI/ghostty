// Coalesces back-to-back scroll requests into a single scheduler tick.
//
// `term.write(bytes)` runs synchronously while the websocket pumps frames,
// and previously every binary frame followed up with
// `setTimeout(scrollTerminalToBottom, 0)` to keep the cursor visible on
// mobile. A noisy producer (`cat large.log`, `npm install`, …) queues
// hundreds of those timeouts per second; each one ran a full
// scroll-to-bottom on the next macrotask, dwarfing the actual render
// cost. Folding them into one scheduler tick (rAF in production) caps
// the work at one scroll per ~16 ms while keeping the cursor visible in
// real time.

export function createCoalescedScroll(scheduler, scroll) {
  let pending = false;
  return function request() {
    if (pending) return;
    pending = true;
    scheduler(() => {
      pending = false;
      scroll();
    });
  };
}
