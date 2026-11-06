const i18n = @import("../i18n.zig");
const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const widgets = @import("../widgets.zig");

/// Render a style as a table.
pub fn table(
    st: terminal.Style,
    palette: ?*const terminal.color.Palette,
) void {
    {
        _ = cimgui.c.ImGui_BeginTable(
            "style",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();
        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text(i18n._("Foreground"));
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker(i18n._("The foreground (text) color"));
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("fg", st.fg_color, palette);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text(i18n._("Background"));
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker(i18n._("The background (cell) color"));
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("bg", st.bg_color, palette);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text(i18n._("Underline"));
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker(i18n._("The underline color, if underlines are enabled."));
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("underline", st.underline_color, palette);
        }

        const style_flags = .{
            .{ "bold", i18n.N_("Text will be rendered with bold weight.") },
            .{ "italic", i18n.N_("Text will be rendered in italic style.") },
            .{ "faint", i18n.N_("Text will be rendered with reduced intensity.") },
            .{ "blink", i18n.N_("Text will blink.") },
            .{ "inverse", i18n.N_("Foreground and background colors are swapped.") },
            .{ "invisible", i18n.N_("Text will be invisible (hidden).") },
            .{ "strikethrough", i18n.N_("Text will have a line through it.") },
        };
        inline for (style_flags) |entry| entry: {
            const style = entry[0];
            const help = entry[1];
            if (!@field(st.flags, style)) break :entry;

            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text(style.ptr);
                cimgui.c.ImGui_SameLine();
                widgets.helpMarker(i18n._(help));
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text("true");
            }
        }
    }

    cimgui.c.ImGui_TextDisabled(i18n._("(Any styles not shown are not currently set)"));
}

/// Render a style color.
pub fn color(
    id: [:0]const u8,
    c: terminal.Style.Color,
    palette: ?*const terminal.color.Palette,
) void {
    cimgui.c.ImGui_PushID(id);
    defer cimgui.c.ImGui_PopID();

    switch (c) {
        .none => cimgui.c.ImGui_Text(i18n._("default")),

        .palette => |idx| {
            cimgui.c.ImGui_Text(i18n._("Palette %d"), idx);
            if (palette) |p| {
                const rgb = p[idx];
                var data: [3]f32 = .{
                    @as(f32, @floatFromInt(rgb.r)) / 255,
                    @as(f32, @floatFromInt(rgb.g)) / 255,
                    @as(f32, @floatFromInt(rgb.b)) / 255,
                };
                _ = cimgui.c.ImGui_ColorEdit3(
                    "color_fg",
                    &data,
                    cimgui.c.ImGuiColorEditFlags_DisplayHex |
                        cimgui.c.ImGuiColorEditFlags_NoPicker |
                        cimgui.c.ImGuiColorEditFlags_NoLabel,
                );
            }
        },

        .rgb => |rgb| {
            var data: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_fg",
                &data,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }
}
