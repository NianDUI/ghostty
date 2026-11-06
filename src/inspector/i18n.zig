//! Slice-preserving gettext adapter for the inspector's ImGui widgets.
const std = @import("std");
const i18n = @import("../os/i18n.zig");

pub fn _(msgid: [:0]const u8) [:0]const u8 {
    return std.mem.span(i18n._(msgid));
}

pub const N_ = i18n.N_;
