import { test } from "node:test";
import assert from "node:assert/strict";
import { buildAppearanceTheme, PALETTE_KEYS } from "../src/appearance.js";

test("buildAppearanceTheme returns bg/fg/cursor for the minimal frame", () => {
  const theme = buildAppearanceTheme({
    background: "#171412",
    foreground: "#f5f0e8",
  });
  assert.deepEqual(theme, {
    background: "#171412",
    foreground: "#f5f0e8",
    cursor: "#f5f0e8",
  });
});

test("buildAppearanceTheme expands a 16-entry palette into ANSI keys", () => {
  const palette = Array.from(
    { length: 16 },
    (_, i) => `#${i.toString(16).padStart(2, "0").repeat(3)}`,
  );
  const theme = buildAppearanceTheme({
    background: "#000000",
    foreground: "#ffffff",
    palette,
  });
  for (let i = 0; i < 16; i += 1) {
    assert.equal(theme[PALETTE_KEYS[i]], palette[i]);
  }
});

test("buildAppearanceTheme rejects non-hex colors", () => {
  assert.equal(
    buildAppearanceTheme({ background: "red", foreground: "#ffffff" }),
    null,
  );
  assert.equal(
    buildAppearanceTheme({ background: "#fff", foreground: "#ffffff" }),
    null,
  );
});

test("buildAppearanceTheme rejects a palette with an invalid entry", () => {
  const palette = Array(16).fill("#000000");
  palette[5] = "not-a-color";
  assert.equal(
    buildAppearanceTheme({
      background: "#000000",
      foreground: "#ffffff",
      palette,
    }),
    null,
  );
});

test("buildAppearanceTheme ignores a palette shorter than 16 entries", () => {
  const theme = buildAppearanceTheme({
    background: "#000000",
    foreground: "#ffffff",
    palette: ["#111111"],
  });
  assert.equal(theme.background, "#000000");
  assert.equal(theme.black, undefined);
});

test("buildAppearanceTheme returns null for non-objects", () => {
  assert.equal(buildAppearanceTheme(null), null);
  assert.equal(buildAppearanceTheme(undefined), null);
  assert.equal(buildAppearanceTheme("nope"), null);
});
