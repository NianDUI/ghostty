const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

export const PALETTE_KEYS = [
  "black",
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
  "brightBlack",
  "brightRed",
  "brightGreen",
  "brightYellow",
  "brightBlue",
  "brightMagenta",
  "brightCyan",
  "brightWhite",
];

function isHexColor(value) {
  return typeof value === "string" && HEX_COLOR_RE.test(value);
}

export function buildAppearanceTheme(frame) {
  if (!frame || typeof frame !== "object") return null;
  if (!isHexColor(frame.background) || !isHexColor(frame.foreground))
    return null;
  const theme = {
    background: frame.background,
    foreground: frame.foreground,
    cursor: frame.foreground,
  };
  if (Array.isArray(frame.palette) && frame.palette.length >= 16) {
    for (let i = 0; i < 16; i += 1) {
      const color = frame.palette[i];
      if (!isHexColor(color)) return null;
      theme[PALETTE_KEYS[i]] = color;
    }
  }
  return theme;
}
