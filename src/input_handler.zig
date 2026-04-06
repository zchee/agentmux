const std = @import("std");
const input = @import("terminal/input.zig");
const screen_mod = @import("screen/screen.zig");
const writer_mod = @import("screen/writer.zig");
const colour = @import("core/colour.zig");

const Screen = screen_mod.Screen;
const Writer = writer_mod.Writer;
const InputEvent = input.InputEvent;
const CSI = input.CSI;

/// Process a stream of bytes through the input parser and apply to screen.
pub fn processBytes(parser: *input.Parser, scr: *Screen, data: []const u8) void {
    for (data) |byte| {
        if (parser.feed(byte)) |event| {
            handleEvent(scr, event);
        }
    }
}

/// Handle a single parsed input event.
pub fn handleEvent(scr: *Screen, event: InputEvent) void {
    switch (event) {
        .print => |cp| {
            var w = Writer.init(scr);
            w.putChar(cp);
        },
        .c0 => |c| handleC0(scr, c),
        .csi => |csi| handleCSI(scr, csi),
        .esc => |esc| handleESC(scr, esc),
        .osc => |osc| handleOSC(scr, osc),
        .dcs => {},
    }
}

fn handleC0(scr: *Screen, c: u8) void {
    var w = Writer.init(scr);
    switch (c) {
        0x07 => {}, // BEL - bell
        0x08 => w.backspace(), // BS
        0x09 => w.tab(), // HT
        0x0A, 0x0B, 0x0C => w.linefeed(), // LF, VT, FF
        0x0D => w.carriageReturn(), // CR
        0x0E => {}, // SO - shift out (ACS)
        0x0F => {}, // SI - shift in
        else => {},
    }
}

fn handleCSI(scr: *Screen, csi: CSI) void {
    // Check for private mode marker
    if (csi.intermediate_count > 0 and csi.intermediates[0] == '?') {
        handleCSIPrivate(scr, csi);
        return;
    }

    var w = Writer.init(scr);
    switch (csi.final) {
        'A' => { // CUU - cursor up
            scr.cursorUp(csi.getParam(0, 1));
        },
        'B' => { // CUD - cursor down
            scr.cursorDown(csi.getParam(0, 1));
        },
        'C' => { // CUF - cursor forward
            const n = csi.getParam(0, 1);
            scr.cx = @min(scr.cx + n, scr.grid.cols -| 1);
        },
        'D' => { // CUB - cursor back
            const n = csi.getParam(0, 1);
            scr.cx = if (scr.cx >= n) scr.cx - n else 0;
        },
        'E' => { // CNL - cursor next line
            scr.cursorDown(csi.getParam(0, 1));
            scr.cx = 0;
        },
        'F' => { // CPL - cursor previous line
            scr.cursorUp(csi.getParam(0, 1));
            scr.cx = 0;
        },
        'G' => { // CHA - cursor character absolute
            const col = csi.getParam(0, 1);
            scr.cx = @min(if (col > 0) col - 1 else 0, scr.grid.cols -| 1);
        },
        'H', 'f' => { // CUP/HVP - cursor position
            const row = csi.getParam(0, 1);
            const col = csi.getParam(1, 1);
            scr.cursorTo(if (col > 0) col - 1 else 0, if (row > 0) row - 1 else 0);
        },
        'J' => { // ED - erase display
            const mode_param = csi.getParam(0, 0);
            switch (mode_param) {
                0 => w.eraseToEnd(),
                1 => w.eraseToStart(),
                2 => w.eraseScreen(),
                else => {},
            }
        },
        'K' => { // EL - erase line
            const mode_param = csi.getParam(0, 0);
            switch (mode_param) {
                0 => w.eraseToEol(),
                1 => w.eraseToBol(),
                2 => w.eraseLine(),
                else => {},
            }
        },
        'L' => { // IL - insert lines
            w.insertLines(csi.getParam(0, 1));
        },
        'M' => { // DL - delete lines
            w.deleteLines(csi.getParam(0, 1));
        },
        'P' => { // DCH - delete characters
            w.deleteChars(csi.getParam(0, 1));
        },
        'S' => { // SU - scroll up
            scr.scrollUp(csi.getParam(0, 1));
        },
        'T' => { // SD - scroll down
            scr.scrollDown(csi.getParam(0, 1));
        },
        '@' => { // ICH - insert characters
            w.insertChars(csi.getParam(0, 1));
        },
        'd' => { // VPA - line position absolute
            const row = csi.getParam(0, 1);
            scr.cy = @min(if (row > 0) row - 1 else 0, scr.grid.rows -| 1);
        },
        'm' => { // SGR - select graphic rendition
            handleSGR(scr, &csi);
        },
        'r' => { // DECSTBM - set scroll region
            const top = csi.getParam(0, 1);
            const bottom = csi.getParam(1, @intCast(@min(scr.grid.rows, 0xFFFF)));
            scr.setScrollRegion(top, bottom);
            scr.cursorTo(0, 0);
        },
        'h' => { // SM - set mode
            handleSetMode(scr, &csi, true);
        },
        'l' => { // RM - reset mode
            handleSetMode(scr, &csi, false);
        },
        'X' => { // ECH - erase characters
            w.eraseChars(csi.getParam(0, 1));
        },
        'b' => { // REP - repeat last character
            const n = csi.getParam(0, 1);
            // Repeat the character at the current cursor position
            if (scr.cx > 0) {
                const prev = scr.grid.getCell(scr.cx - 1, scr.cy);
                const cp = prev.codepoint;
                if (cp != 0) {
                    var j: u32 = 0;
                    while (j < n) : (j += 1) {
                        w.putChar(cp);
                    }
                }
            }
        },
        's' => { // ANSI cursor save (not DECSC — no intermediates)
            scr.saveCursor();
        },
        'u' => { // ANSI cursor restore (not DECRC — no intermediates)
            scr.restoreCursor();
        },
        'g' => { // TBC - tab clear
            // 0 = clear tab at current column, 3 = clear all tabs
            // (tab stops not yet tracked, so this is a no-op for now)
        },
        'n' => {}, // DSR - device status report (handled by server)
        'c' => {}, // DA - device attributes (handled by server)
        else => {},
    }
}

fn handleCSIPrivate(scr: *Screen, csi: CSI) void {
    switch (csi.final) {
        'h' => handleDecSet(scr, &csi, true),
        'l' => handleDecSet(scr, &csi, false),
        else => {},
    }
}

fn handleDecSet(scr: *Screen, csi: *const CSI, enable: bool) void {
    var i: u5 = 0;
    while (i < csi.param_count) : (i += 1) {
        switch (csi.params[i]) {
            1 => scr.mode.app_cursor = enable, // DECCKM
            6 => { // DECOM - origin mode
                scr.mode.origin = enable;
                scr.cursorTo(0, 0);
            },
            7 => scr.mode.wrap = enable, // DECAWM
            25 => scr.mode.cursor_visible = enable, // DECTCEM
            47, 1047 => { // Alt screen (without cursor save/restore)
                if (enable) {
                    scr.enterAltScreen();
                } else {
                    scr.leaveAltScreen();
                }
            },
            1000 => scr.mode.mouse_standard = enable, // Mouse tracking
            1002 => scr.mode.mouse_button = enable, // Button event mouse
            1003 => scr.mode.mouse_any = enable, // Any event mouse
            1006 => scr.mode.mouse_sgr = enable, // SGR mouse
            1049 => { // Alt screen + save/restore cursor
                if (enable) {
                    scr.saveCursor();
                    scr.enterAltScreen();
                } else {
                    scr.leaveAltScreen();
                    scr.restoreCursor();
                }
            },
            2004 => scr.mode.bracketed_paste = enable, // Bracketed paste
            1004 => scr.mode.focus_events = enable, // Focus events
            else => {},
        }
    }
}

fn handleSetMode(scr: *Screen, csi: *const CSI, enable: bool) void {
    var i: u5 = 0;
    while (i < csi.param_count) : (i += 1) {
        switch (csi.params[i]) {
            4 => scr.mode.insert = enable, // IRM
            else => {},
        }
    }
}

fn handleSGR(scr: *Screen, csi: *const CSI) void {
    if (csi.param_count == 0) {
        // ESC[m = reset all attributes
        scr.cell.fg = .default;
        scr.cell.bg = .default;
        scr.cell.attrs = .{};
        return;
    }

    var i: u5 = 0;
    while (i < csi.param_count) : (i += 1) {
        const p = csi.params[i];
        switch (p) {
            0 => { // Reset
                scr.cell.fg = .default;
                scr.cell.bg = .default;
                scr.cell.attrs = .{};
            },
            1 => scr.cell.attrs.bold = true,
            2 => scr.cell.attrs.dim = true,
            3 => scr.cell.attrs.italic = true,
            4 => scr.cell.attrs.underline = true,
            5 => scr.cell.attrs.blink = true,
            7 => scr.cell.attrs.reverse = true,
            8 => scr.cell.attrs.hidden = true,
            9 => scr.cell.attrs.strikethrough = true,
            21 => scr.cell.attrs.bold = false,
            22 => {
                scr.cell.attrs.bold = false;
                scr.cell.attrs.dim = false;
            },
            23 => scr.cell.attrs.italic = false,
            24 => scr.cell.attrs.underline = false,
            25 => scr.cell.attrs.blink = false,
            27 => scr.cell.attrs.reverse = false,
            28 => scr.cell.attrs.hidden = false,
            29 => scr.cell.attrs.strikethrough = false,
            // Foreground colors
            30...37 => scr.cell.fg = .{ .palette = @intCast(p - 30) },
            38 => {
                if (parseSgrColor(csi, &i)) |c| scr.cell.fg = c;
            },
            39 => scr.cell.fg = .default,
            // Background colors
            40...47 => scr.cell.bg = .{ .palette = @intCast(p - 40) },
            48 => {
                if (parseSgrColor(csi, &i)) |c| scr.cell.bg = c;
            },
            49 => scr.cell.bg = .default,
            // Bright foreground
            90...97 => scr.cell.fg = .{ .palette = @intCast(p - 90 + 8) },
            // Bright background
            100...107 => scr.cell.bg = .{ .palette = @intCast(p - 100 + 8) },
            else => {},
        }
    }
}

/// Parse 256-color or RGB color from SGR params (38;5;N or 38;2;R;G;B).
fn parseSgrColor(csi: *const CSI, i: *u5) ?colour.Colour {
    if (i.* + 1 >= csi.param_count) return null;
    i.* += 1;
    switch (csi.params[i.*]) {
        5 => { // 256-color: 38;5;N
            if (i.* + 1 >= csi.param_count) return null;
            i.* += 1;
            return .{ .palette = @intCast(csi.params[i.*]) };
        },
        2 => { // RGB: 38;2;R;G;B
            if (i.* + 3 >= csi.param_count) return null;
            i.* += 1;
            const r: u8 = @intCast(@min(csi.params[i.*], 255));
            i.* += 1;
            const g: u8 = @intCast(@min(csi.params[i.*], 255));
            i.* += 1;
            const b: u8 = @intCast(@min(csi.params[i.*], 255));
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        },
        else => return null,
    }
}

fn handleESC(scr: *Screen, esc: input.ESC) void {
    switch (esc.final) {
        '7' => scr.saveCursor(), // DECSC
        '8' => scr.restoreCursor(), // DECRC
        'M' => { // RI - reverse index
            var w = Writer.init(scr);
            w.reverseIndex();
        },
        'c' => scr.reset(), // RIS - full reset
        'D' => { // IND - index (linefeed)
            var w = Writer.init(scr);
            w.linefeed();
        },
        'E' => { // NEL - next line
            var w = Writer.init(scr);
            w.carriageReturn();
            w.linefeed();
        },
        else => {},
    }
}

fn handleOSC(scr: *Screen, osc: input.OSC) void {
    switch (osc.ps) {
        0, 2 => { // Set window title
            scr.setTitle(osc.getData()) catch {};
        },
        1 => { // Set icon name (treat as title)
            scr.setTitle(osc.getData()) catch {};
        },
        else => {},
    }
}

test "process cursor movement" {
    var scr = Screen.init(std.testing.allocator, 80, 24, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    // ESC[5;10H -> move to row 5, col 10 (1-based)
    processBytes(&parser, &scr, "\x1b[5;10H");
    try std.testing.expectEqual(@as(u32, 9), scr.cx); // 0-based
    try std.testing.expectEqual(@as(u32, 4), scr.cy);
}

test "process SGR colors" {
    var scr = Screen.init(std.testing.allocator, 80, 24, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    // ESC[31m -> set fg red
    processBytes(&parser, &scr, "\x1b[31m");
    try std.testing.expectEqual(colour.Colour{ .palette = 1 }, scr.cell.fg);

    // ESC[0m -> reset
    processBytes(&parser, &scr, "\x1b[0m");
    try std.testing.expectEqual(colour.Colour.default, scr.cell.fg);
}

test "process print and linefeed" {
    var scr = Screen.init(std.testing.allocator, 80, 24, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    processBytes(&parser, &scr, "AB");
    try std.testing.expectEqual(@as(u32, 2), scr.cx);
    try std.testing.expectEqual(@as(u21, 'A'), scr.grid.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), scr.grid.getCell(1, 0).codepoint);

    processBytes(&parser, &scr, "\r\n"); // CR LF
    try std.testing.expectEqual(@as(u32, 0), scr.cx);
    try std.testing.expectEqual(@as(u32, 1), scr.cy);
}

test "process DEC private modes" {
    var scr = Screen.init(std.testing.allocator, 80, 24, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    // Hide cursor
    processBytes(&parser, &scr, "\x1b[?25l");
    try std.testing.expect(!scr.mode.cursor_visible);

    // Show cursor
    processBytes(&parser, &scr, "\x1b[?25h");
    try std.testing.expect(scr.mode.cursor_visible);
}

test "process erase" {
    var scr = Screen.init(std.testing.allocator, 10, 3, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    // Write some text
    processBytes(&parser, &scr, "ABCDEFGHIJ");
    // Move to col 5, erase to EOL
    processBytes(&parser, &scr, "\x1b[1;6H"); // row 1, col 6
    processBytes(&parser, &scr, "\x1b[K");
    try std.testing.expectEqual(@as(u21, 'E'), scr.grid.getCell(4, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), scr.grid.getCell(5, 0).codepoint);
}

test "process ECH erase characters" {
    var scr = Screen.init(std.testing.allocator, 10, 3, 0);
    defer scr.deinit();
    var parser = input.Parser.init();

    processBytes(&parser, &scr, "ABCDEFGHIJ");
    // Move to col 3, erase 4 characters
    processBytes(&parser, &scr, "\x1b[1;4H"); // row 1, col 4
    processBytes(&parser, &scr, "\x1b[4X"); // erase 4 chars
    try std.testing.expectEqual(@as(u21, 'C'), scr.grid.getCell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), scr.grid.getCell(3, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), scr.grid.getCell(6, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), scr.grid.getCell(7, 0).codepoint);
}
