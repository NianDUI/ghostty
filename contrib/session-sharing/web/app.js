const tokenInput = document.querySelector("#token");
const saveTokenButton = document.querySelector("#saveToken");
const sessionList = document.querySelector("#sessionList");
const sessionMeta = document.querySelector("#sessionMeta");
const terminal = document.querySelector("#terminal");
const input = document.querySelector("#input");
const sendInputButton = document.querySelector("#sendInput");
const connectedName = document.querySelector("#connectedName");
const connectionMeta = document.querySelector("#connectionMeta");

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

const RESULT_SUCCESS = 0;
const RESULT_INVALID_VALUE = -2;

const RENDER_STATE_DATA = {
  COLS: 1,
  ROWS: 2,
  CURSOR_VISIBLE: 11,
  CURSOR_VIEWPORT_HAS_VALUE: 14,
  CURSOR_VIEWPORT_X: 15,
  CURSOR_VIEWPORT_Y: 16,
};

const RENDER_STATE_ROW_CELLS_DATA = {
  RAW: 1,
  STYLE: 2,
  GRAPHEMES_LEN: 3,
  GRAPHEMES_BUF: 4,
  BG_COLOR: 5,
  FG_COLOR: 6,
};

const CELL_DATA = {
  WIDE: 3,
};

const CELL_WIDE = {
  NARROW: 0,
  WIDE: 1,
  SPACER_TAIL: 2,
  SPACER_HEAD: 3,
};

const STYLE_COLOR_TAG = {
  NONE: 0,
  PALETTE: 1,
  RGB: 2,
};

let socket = null;
let activeSession = null;
let vt = null;

tokenInput.value = localStorage.getItem("ghostty-sharing-token") ?? "";

saveTokenButton.addEventListener("click", async () => {
  localStorage.setItem("ghostty-sharing-token", tokenInput.value.trim());
  await refreshSessions();
});

sendInputButton.addEventListener("click", () => {
  const text = input.value;
  if (!text) return;
  sendTerminalBytes(textEncoder.encode(text));
  input.value = "";
});

input.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    sendInputButton.click();
  }
});

terminal.addEventListener("keydown", (event) => {
  const bytes = encodeKeyEvent(event);
  if (!bytes) return;
  event.preventDefault();
  sendTerminalBytes(bytes);
});

terminal.addEventListener("click", () => {
  terminal.focus();
});

async function ensureTerminalEngine() {
  if (vt) return vt;
  connectionMeta.textContent = "加载 Ghostty WASM...";
  vt = await createGhosttyTerminal({
    wasmURL: "./ghostty-vt.wasm",
    mount: terminal,
  });
  connectionMeta.textContent = "等待选择会话";
  return vt;
}

async function refreshSessions() {
  const token = tokenInput.value.trim();
  sessionList.innerHTML = "";
  sessionMeta.textContent = token ? "加载中..." : "缺少用户令牌";
  if (!token) return;

  try {
    const response = await fetch("/api/sessions", {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    if (!response.ok) {
      sessionMeta.textContent = `请求失败 (${response.status})`;
      return;
    }

    const sessions = await response.json();
    sessionMeta.textContent = `${sessions.length} 个会话`;
    for (const session of sessions) {
      sessionList.append(renderSession(session));
    }
  } catch (error) {
    console.error(error);
    sessionMeta.textContent = "请求失败";
  }
}

function renderSession(session) {
  const item = document.createElement("button");
  item.type = "button";
  item.className = `session ${session.online ? "" : "offline"}`.trim();
  item.innerHTML = `
    <div><strong>${escapeHtml(session.name)}</strong></div>
    <div style="margin-top: 6px; font-size: 12px; color: #6d655c;">${escapeHtml(session.id)}</div>
    <div class="status ${session.online ? "online" : "offline"}">${session.online ? "在线" : "离线"}</div>
  `;
  if (session.online) {
    item.addEventListener("click", () => connectToSession(session));
  } else {
    item.disabled = true;
  }
  return item;
}

async function connectToSession(session) {
  await ensureTerminalEngine();

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const url = new URL(`${protocol}//${location.host}/ws/client`);
  url.searchParams.set("id", session.id);
  url.searchParams.set("token", session.client_token);

  if (socket) socket.close();
  activeSession = session;
  connectedName.textContent = session.name;
  connectionMeta.textContent = "连接中";
  vt.reset();
  terminal.focus();

  socket = new WebSocket(url);
  socket.binaryType = "arraybuffer";

  socket.addEventListener("open", () => {
    connectionMeta.textContent = "已连接";
  });

  socket.addEventListener("close", () => {
    connectionMeta.textContent = "连接关闭";
  });

  socket.addEventListener("message", async (event) => {
    if (typeof event.data === "string") {
      await handleTextFrame(event.data);
      return;
    }

    const bytes = new Uint8Array(event.data);
    vt.write(bytes);
  });
}

async function handleTextFrame(data) {
  const engine = await ensureTerminalEngine();
  try {
    const frame = JSON.parse(data);
    switch (frame.type) {
      case "hello":
        if (Number.isInteger(frame.cols) && Number.isInteger(frame.rows)) {
          engine.resize(frame.cols, frame.rows);
        }
        if (frame.name) {
          connectedName.textContent = frame.name;
        }
        return;
      case "resize":
        if (Number.isInteger(frame.cols) && Number.isInteger(frame.rows)) {
          engine.resize(frame.cols, frame.rows);
        }
        return;
      case "ping":
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ type: "pong", id: activeSession?.id ?? "" }));
        }
        return;
      case "pong":
        return;
      default:
        return;
    }
  } catch (_) {
    engine.write(textEncoder.encode(data));
  }
}

function sendTerminalBytes(bytes) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(bytes);
  terminal.focus();
}

function encodeKeyEvent(event) {
  if (event.metaKey) return null;

  if (event.ctrlKey && !event.altKey && event.key.length === 1) {
    const upper = event.key.toUpperCase();
    if (upper >= "A" && upper <= "Z") {
      return Uint8Array.of(upper.charCodeAt(0) - 64);
    }
  }

  switch (event.key) {
    case "Enter":
      return Uint8Array.of(0x0d);
    case "Backspace":
      return Uint8Array.of(0x7f);
    case "Tab":
      return Uint8Array.of(event.shiftKey ? 0x1b : 0x09, ...(event.shiftKey ? [0x5b, 0x5a] : []));
    case "Escape":
      return Uint8Array.of(0x1b);
    case "ArrowUp":
      return textEncoder.encode("\u001b[A");
    case "ArrowDown":
      return textEncoder.encode("\u001b[B");
    case "ArrowRight":
      return textEncoder.encode("\u001b[C");
    case "ArrowLeft":
      return textEncoder.encode("\u001b[D");
    case "Home":
      return textEncoder.encode("\u001b[H");
    case "End":
      return textEncoder.encode("\u001b[F");
    case "Delete":
      return textEncoder.encode("\u001b[3~");
    case "PageUp":
      return textEncoder.encode("\u001b[5~");
    case "PageDown":
      return textEncoder.encode("\u001b[6~");
    default:
      break;
  }

  if (!event.ctrlKey && !event.altKey && event.key.length === 1) {
    return textEncoder.encode(event.key);
  }

  return null;
}

async function createGhosttyTerminal({ wasmURL, mount }) {
  const response = await fetch(wasmURL);
  if (!response.ok) {
    throw new Error(`failed to load wasm: ${response.status}`);
  }

  const { instance } = await WebAssembly.instantiateStreaming(response, {
    env: {
      log() {},
    },
  });

  const exports = instance.exports;
  const layouts = JSON.parse(readCString(exports, exports.ghostty_type_json()));
  const api = createWasmApi(exports, layouts);

  return new GhosttyBrowserTerminal(api, mount);
}

function createWasmApi(exports, layouts) {
  function memoryView() {
    return new DataView(exports.memory.buffer);
  }

  function uint8View() {
    return new Uint8Array(exports.memory.buffer);
  }

  function allocOpaque() {
    return exports.ghostty_wasm_alloc_opaque();
  }

  function allocBytes(length) {
    return exports.ghostty_wasm_alloc_u8_array(length);
  }

  function freeBytes(ptr, length) {
    if (ptr) exports.ghostty_wasm_free_u8_array(ptr, length);
  }

  function allocValue(length) {
    return allocBytes(length);
  }

  function readPointer(ptr) {
    return memoryView().getUint32(ptr, true);
  }

  function writeBytes(ptr, bytes) {
    uint8View().set(bytes, ptr);
  }

  function readU16(ptr) {
    return memoryView().getUint16(ptr, true);
  }

  function readU32(ptr) {
    return memoryView().getUint32(ptr, true);
  }

  function readU64(ptr) {
    return Number(memoryView().getBigUint64(ptr, true));
  }

  function readBool(ptr) {
    return memoryView().getUint8(ptr) !== 0;
  }

  function readEnum(ptr) {
    return memoryView().getInt32(ptr, true);
  }

  function readColor(ptr) {
    const view = memoryView();
    return {
      r: view.getUint8(ptr + layouts.GhosttyColorRgb.fields.r.offset),
      g: view.getUint8(ptr + layouts.GhosttyColorRgb.fields.g.offset),
      b: view.getUint8(ptr + layouts.GhosttyColorRgb.fields.b.offset),
    };
  }

  function writeTerminalOptions(ptr, cols, rows, scrollback) {
    const view = memoryView();
    const fields = layouts.GhosttyTerminalOptions.fields;
    view.setUint16(ptr + fields.cols.offset, cols, true);
    view.setUint16(ptr + fields.rows.offset, rows, true);
    view.setBigUint64(ptr + fields.max_scrollback.offset, BigInt(scrollback), true);
  }

  function initSizedStruct(ptr, typeName) {
    const layout = layouts[typeName];
    const view = uint8View();
    view.fill(0, ptr, ptr + layout.size);
    memoryView().setBigUint64(ptr, BigInt(layout.size), true);
  }

  return {
    exports,
    layouts,
    allocOpaque,
    allocBytes,
    freeBytes,
    allocValue,
    readPointer,
    writeBytes,
    readU16,
    readU32,
    readU64,
    readBool,
    readEnum,
    readColor,
    writeTerminalOptions,
    initSizedStruct,
  };
}

class GhosttyBrowserTerminal {
  constructor(api, mount) {
    this.api = api;
    this.mount = mount;
    this.rowNodes = [];
    this.renderQueued = false;
    this.currentCols = 120;
    this.currentRows = 32;

    this.handlePtrPtr = api.allocOpaque();
    this.renderStatePtrPtr = api.allocOpaque();
    this.rowIteratorPtrPtr = api.allocOpaque();
    this.rowCellsPtrPtr = api.allocOpaque();

    this.terminalOptionsPtr = api.allocBytes(api.layouts.GhosttyTerminalOptions.size);
    this.colorsPtr = api.allocBytes(api.layouts.GhosttyRenderStateColors.size);
    this.stylePtr = api.allocBytes(api.layouts.GhosttyStyle.size);
    this.u16Ptr = api.allocValue(4);
    this.u32Ptr = api.allocValue(4);
    this.u8Ptr = api.allocValue(1);
    this.cellPtr = api.allocValue(8);

    api.initSizedStruct(this.colorsPtr, "GhosttyRenderStateColors");
    api.initSizedStruct(this.stylePtr, "GhosttyStyle");

    this.createTerminal(this.currentCols, this.currentRows);
    this.mount.textContent = "";
    this.mount.style.setProperty("--cols", String(this.currentCols));
  }

  createTerminal(cols, rows) {
    const { exports, writeTerminalOptions, readPointer } = this.api;
    writeTerminalOptions(this.terminalOptionsPtr, cols, rows, 5000);

    this.check(exports.ghostty_terminal_new(0, this.handlePtrPtr, this.terminalOptionsPtr));
    this.terminalHandle = readPointer(this.handlePtrPtr);

    this.check(exports.ghostty_render_state_new(0, this.renderStatePtrPtr));
    this.renderStateHandle = readPointer(this.renderStatePtrPtr);

    this.check(exports.ghostty_render_state_row_iterator_new(0, this.rowIteratorPtrPtr));
    this.rowIteratorHandle = readPointer(this.rowIteratorPtrPtr);

    this.check(exports.ghostty_render_state_row_cells_new(0, this.rowCellsPtrPtr));
    this.rowCellsHandle = readPointer(this.rowCellsPtrPtr);

    this.resize(cols, rows);
  }

  reset() {
    this.api.exports.ghostty_terminal_reset(this.terminalHandle);
    this.scheduleRender();
  }

  resize(cols, rows) {
    this.currentCols = Math.max(1, Number(cols) || 1);
    this.currentRows = Math.max(1, Number(rows) || 1);
    this.mount.style.setProperty("--cols", String(this.currentCols));
    this.check(
      this.api.exports.ghostty_terminal_resize(
        this.terminalHandle,
        this.currentCols,
        this.currentRows,
        10,
        20,
      ),
    );
    this.ensureRows(this.currentRows);
    this.scheduleRender();
  }

  write(bytes) {
    const ptr = this.api.allocBytes(bytes.length);
    this.api.writeBytes(ptr, bytes);
    this.api.exports.ghostty_terminal_vt_write(this.terminalHandle, ptr, bytes.length);
    this.api.freeBytes(ptr, bytes.length);
    this.scheduleRender();
  }

  scheduleRender() {
    if (this.renderQueued) return;
    this.renderQueued = true;
    requestAnimationFrame(() => {
      this.renderQueued = false;
      this.render();
    });
  }

  render() {
    const { exports, readU16, readBool, readColor, readEnum, readPointer, readU32, initSizedStruct, layouts } = this.api;

    this.check(exports.ghostty_render_state_update(this.renderStateHandle, this.terminalHandle));
    this.check(exports.ghostty_render_state_colors_get(this.renderStateHandle, this.colorsPtr));

    const colorFields = layouts.GhosttyRenderStateColors.fields;
    const defaultBackground = readColor(this.colorsPtr + colorFields.background.offset);
    const defaultForeground = readColor(this.colorsPtr + colorFields.foreground.offset);

    this.check(exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.COLS, this.u16Ptr));
    this.check(exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.ROWS, this.u16Ptr + 2));
    const cols = readU16(this.u16Ptr);
    const rows = readU16(this.u16Ptr + 0);

    this.ensureRows(rows);

    let cursorVisible = false;
    let cursorX = -1;
    let cursorY = -1;
    if (exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.CURSOR_VISIBLE, this.u8Ptr) === RESULT_SUCCESS) {
      cursorVisible = readBool(this.u8Ptr);
    }
    if (
      cursorVisible &&
      exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.CURSOR_VIEWPORT_HAS_VALUE, this.u8Ptr) === RESULT_SUCCESS &&
      readBool(this.u8Ptr)
    ) {
      this.check(exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.CURSOR_VIEWPORT_X, this.u16Ptr));
      this.check(exports.ghostty_render_state_get(this.renderStateHandle, RENDER_STATE_DATA.CURSOR_VIEWPORT_Y, this.u16Ptr + 2));
      cursorX = readU16(this.u16Ptr);
      cursorY = readU16(this.u16Ptr + 2);
    }

    this.check(
      exports.ghostty_render_state_get(
        this.renderStateHandle,
        4,
        this.rowIteratorPtrPtr,
      ),
    );
    this.rowIteratorHandle = readPointer(this.rowIteratorPtrPtr);

    for (let y = 0; y < rows; y += 1) {
      const rowNode = this.rowNodes[y];
      rowNode.textContent = "";

      if (!exports.ghostty_render_state_row_iterator_next(this.rowIteratorHandle)) {
        continue;
      }

      this.check(
        exports.ghostty_render_state_row_get(
          this.rowIteratorHandle,
          3,
          this.rowCellsPtrPtr,
        ),
      );
      this.rowCellsHandle = readPointer(this.rowCellsPtrPtr);

      for (let x = 0; x < cols; x += 1) {
        if (!exports.ghostty_render_state_row_cells_next(this.rowCellsHandle)) {
          break;
        }

        this.check(
          exports.ghostty_render_state_row_cells_get(
            this.rowCellsHandle,
            RENDER_STATE_ROW_CELLS_DATA.RAW,
            this.cellPtr,
          ),
        );
        const cell = readU64(this.cellPtr);
        this.check(exports.ghostty_cell_get(cell, CELL_DATA.WIDE, this.u32Ptr));
        const wide = readEnum(this.u32Ptr);
        if (wide === CELL_WIDE.SPACER_TAIL || wide === CELL_WIDE.SPACER_HEAD) {
          continue;
        }

        this.check(
          exports.ghostty_render_state_row_cells_get(
            this.rowCellsHandle,
            RENDER_STATE_ROW_CELLS_DATA.GRAPHEMES_LEN,
            this.u32Ptr,
          ),
        );
        const graphemeCount = readU32(this.u32Ptr);
        const text = graphemeCount > 0 ? this.readGraphemeText(graphemeCount) : " ";

        initSizedStruct(this.stylePtr, "GhosttyStyle");
        this.check(
          exports.ghostty_render_state_row_cells_get(
            this.rowCellsHandle,
            RENDER_STATE_ROW_CELLS_DATA.STYLE,
            this.stylePtr,
          ),
        );

        const fgColor = this.readResolvedColor(
          exports.ghostty_render_state_row_cells_get(
            this.rowCellsHandle,
            RENDER_STATE_ROW_CELLS_DATA.FG_COLOR,
            this.cellPtr,
          ),
          this.cellPtr,
          defaultForeground,
        );
        const bgColor = this.readResolvedColor(
          exports.ghostty_render_state_row_cells_get(
            this.rowCellsHandle,
            RENDER_STATE_ROW_CELLS_DATA.BG_COLOR,
            this.cellPtr,
          ),
          this.cellPtr,
          defaultBackground,
        );

        rowNode.append(this.renderCell(text, fgColor, bgColor, x === cursorX && y === cursorY));
      }
    }

    for (let y = rows; y < this.rowNodes.length; y += 1) {
      this.rowNodes[y].textContent = "";
    }
  }

  readResolvedColor(result, ptr, fallback) {
    if (result === RESULT_SUCCESS) {
      return this.api.readColor(ptr);
    }
    if (result === RESULT_INVALID_VALUE) {
      return fallback;
    }
    this.check(result);
    return fallback;
  }

  readGraphemeText(length) {
    const ptr = this.api.allocBytes(length * 4);
    try {
      this.check(
        this.api.exports.ghostty_render_state_row_cells_get(
          this.rowCellsHandle,
          RENDER_STATE_ROW_CELLS_DATA.GRAPHEMES_BUF,
          ptr,
        ),
      );

      const view = new DataView(this.api.exports.memory.buffer, ptr, length * 4);
      const codepoints = [];
      for (let i = 0; i < length; i += 1) {
        codepoints.push(view.getUint32(i * 4, true));
      }
      return String.fromCodePoint(...codepoints);
    } finally {
      this.api.freeBytes(ptr, length * 4);
    }
  }

  renderCell(text, fgColor, bgColor, isCursor) {
    const span = document.createElement("span");
    span.className = "cell";
    span.textContent = text;
    span.style.color = rgbToCss(fgColor);
    span.style.backgroundColor = rgbToCss(bgColor);

    const styleFields = this.api.layouts.GhosttyStyle.fields;
    const view = new DataView(this.api.exports.memory.buffer, this.stylePtr, this.api.layouts.GhosttyStyle.size);
    const fgTag = view.getInt32(styleFields.fg_color.offset, true);
    const bgTag = view.getInt32(styleFields.bg_color.offset, true);
    const bold = view.getUint8(styleFields.bold.offset) !== 0;
    const italic = view.getUint8(styleFields.italic.offset) !== 0;
    const faint = view.getUint8(styleFields.faint.offset) !== 0;
    const blink = view.getUint8(styleFields.blink.offset) !== 0;
    const inverse = view.getUint8(styleFields.inverse.offset) !== 0;
    const invisible = view.getUint8(styleFields.invisible.offset) !== 0;
    const strikethrough = view.getUint8(styleFields.strikethrough.offset) !== 0;
    const overline = view.getUint8(styleFields.overline.offset) !== 0;
    const underline = view.getInt32(styleFields.underline.offset, true);

    if (fgTag === STYLE_COLOR_TAG.NONE) {
      span.style.color = "";
    }
    if (bgTag === STYLE_COLOR_TAG.NONE) {
      span.style.backgroundColor = "";
    }
    if (bold) span.style.fontWeight = "700";
    if (italic) span.style.fontStyle = "italic";
    if (faint) span.style.opacity = "0.7";
    if (blink) span.classList.add("blink");
    if (underline > 0) span.style.textDecorationLine = "underline";
    if (strikethrough) span.style.textDecorationLine = span.style.textDecorationLine ? `${span.style.textDecorationLine} line-through` : "line-through";
    if (overline) span.style.textDecorationLine = span.style.textDecorationLine ? `${span.style.textDecorationLine} overline` : "overline";
    if (inverse) {
      const currentFg = span.style.color;
      span.style.color = span.style.backgroundColor || currentFg;
      span.style.backgroundColor = currentFg;
    }
    if (invisible) span.style.color = "transparent";
    if (isCursor) span.classList.add("cursor");

    return span;
  }

  ensureRows(rows) {
    while (this.rowNodes.length < rows) {
      const row = document.createElement("div");
      row.className = "term-row";
      this.mount.append(row);
      this.rowNodes.push(row);
    }
  }

  check(result) {
    if (result === RESULT_SUCCESS) return;
    throw new Error(`ghostty-vt call failed: ${result}`);
  }
}

function readCString(exports, ptr) {
  const bytes = new Uint8Array(exports.memory.buffer);
  let end = ptr;
  while (bytes[end] !== 0) end += 1;
  return textDecoder.decode(bytes.subarray(ptr, end));
}

function rgbToCss(color) {
  return `rgb(${color.r} ${color.g} ${color.b})`;
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

ensureTerminalEngine().catch((error) => {
  console.error(error);
  connectionMeta.textContent = "WASM 加载失败";
  terminal.textContent = String(error);
});

refreshSessions();
