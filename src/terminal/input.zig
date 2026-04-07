const std = @import("std");

/// Events produced by the input parser.
pub const InputEvent = union(enum) {
    print: u21,
    c0: u8,
    csi: CSI,
    osc: OSC,
    esc: ESC,
    dcs: DCS,
};

pub const CSI = struct {
    final: u8,
    intermediates: [4]u8 = .{ 0, 0, 0, 0 },
    intermediate_count: u3 = 0,
    params: [16]u16 = .{0} ** 16,
    param_count: u5 = 0,

    pub fn getParam(self: *const CSI, index: usize, default: u16) u16 {
        if (index >= self.param_count) return default;
        const val = self.params[index];
        return if (val == 0) default else val;
    }
};

pub const OSC = struct {
    ps: u16,
    data: [8192]u8 = .{0} ** 8192,
    data_len: u16 = 0,

    pub fn getData(self: *const OSC) []const u8 {
        return self.data[0..self.data_len];
    }
};

pub const ESC = struct {
    final: u8,
    intermediate: u8 = 0,
};

pub const DCS = struct {
    final: u8,
    intermediates: [4]u8 = .{ 0, 0, 0, 0 },
    intermediate_count: u3 = 0,
    params: [16]u16 = .{0} ** 16,
    param_count: u5 = 0,
    data: [4096]u8 = .{0} ** 4096,
    data_len: u16 = 0,

    pub fn getData(self: *const DCS) []const u8 {
        return self.data[0..self.data_len];
    }
};

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    osc_escape,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_escape,
    dcs_ignore,
};

/// VT100/xterm escape sequence parser.
pub const Parser = struct {
    state: State = .ground,
    params: [16]u16 = .{0} ** 16,
    param_count: u5 = 0,
    intermediates: [4]u8 = .{ 0, 0, 0, 0 },
    intermediate_count: u3 = 0,
    osc_buf: [8192]u8 = .{0} ** 8192,
    osc_len: u16 = 0,
    osc_ps: u16 = 0,
    osc_ps_done: bool = false,
    st_escape_pending: bool = false,
    // UTF-8 multi-byte accumulation
    utf8_buf: [4]u8 = .{ 0, 0, 0, 0 },
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,
    dcs_buf: [4096]u8 = .{0} ** 4096,
    dcs_len: u16 = 0,
    dcs_final: u8 = 0,

    pub fn init() Parser {
        return .{};
    }

    /// Feed one byte. Returns an event if a sequence is complete.
    pub fn feed(self: *Parser, byte: u8) ?InputEvent {
        if (self.st_escape_pending) {
            return switch (self.state) {
                .osc_string => self.handleOscSt(byte),
                .dcs_passthrough => self.handleDcsSt(byte),
                else => blk: {
                    self.st_escape_pending = false;
                    break :blk null;
                },
            };
        }

        // If we're accumulating a UTF-8 multi-byte sequence, continue it.
        if (self.utf8_expected > 0) {
            if (byte >= 0x80 and byte <= 0xBF) {
                // Valid continuation byte.
                self.utf8_buf[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_expected) {
                    // Complete sequence u2014 decode and emit.
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch {
                        self.utf8_expected = 0;
                        self.utf8_len = 0;
                        return null;
                    };
                    self.utf8_expected = 0;
                    self.utf8_len = 0;
                    return .{ .print = cp };
                }
                return null;
            } else {
                // Invalid continuation u2014 abort the sequence and
                // re-process this byte from ground state.
                self.utf8_expected = 0;
                self.utf8_len = 0;
                // Fall through to normal processing below.
            }
        }

        if (byte == 0x1b and self.state != .osc_string and self.state != .osc_escape and self.state != .dcs_passthrough and self.state != .dcs_escape) {
            self.resetSequence();
            self.state = .escape;
            return null;
        }
        if (byte == 0x18 or byte == 0x1a) {
            self.state = .ground;
            return null;
        }

        return switch (self.state) {
            .ground => self.handleGround(byte),
            .escape => self.handleEscape(byte),
            .escape_intermediate => self.handleEscapeIntermediate(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .csi_ignore => self.handleCsiIgnore(byte),
            .osc_string => self.handleOscString(byte),
            .osc_escape => self.handleOscEscape(byte),
            .dcs_entry => self.handleDcsEntry(byte),
            .dcs_param => self.handleDcsParam(byte),
            .dcs_intermediate => self.handleDcsIntermediate(byte),
            .dcs_passthrough => self.handleDcsPassthrough(byte),
            .dcs_escape => self.handleDcsEscape(byte),
            .dcs_ignore => null,
        };
    }

    fn handleGround(self: *Parser, byte: u8) ?InputEvent {
        if (byte < 0x20 or byte == 0x7f) return .{ .c0 = byte };

        // UTF-8 lead byte detection.
        if (byte >= 0xC0) {
            const expected = std.unicode.utf8ByteSequenceLength(byte) catch return null;
            if (expected > 1) {
                self.utf8_buf[0] = byte;
                self.utf8_len = 1;
                self.utf8_expected = expected;
                return null;
            }
        }

        // ASCII or single-byte (0x20-0x7E, 0x80-0xBF stray continuation).
        return .{ .print = @as(u21, byte) };
    }

    fn handleEscape(self: *Parser, byte: u8) ?InputEvent {
        if (byte == '[') {
            self.state = .csi_entry;
            return null;
        }
        if (byte == ']') {
            self.state = .osc_string;
            self.osc_len = 0;
            self.osc_ps = 0;
            self.osc_ps_done = false;
            return null;
        }
        if (byte == 'P') {
            self.state = .dcs_entry;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .escape_intermediate;
            return null;
        }
        if (byte >= 0x30 and byte <= 0x7e) {
            self.state = .ground;
            return .{ .esc = .{ .final = byte, .intermediate = if (self.intermediate_count > 0) self.intermediates[0] else 0 } };
        }
        self.state = .ground;
        return null;
    }

    fn handleEscapeIntermediate(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return null;
        }
        if (byte >= 0x30 and byte <= 0x7e) {
            self.state = .ground;
            return .{ .esc = .{ .final = byte, .intermediate = self.intermediates[0] } };
        }
        self.state = .ground;
        return null;
    }

    fn handleCsiEntry(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= '0' and byte <= '9') {
            self.state = .csi_param;
            if (self.param_count == 0) self.param_count = 1;
            self.params[self.param_count - 1] = byte - '0';
            return null;
        }
        if (byte == ';') {
            self.state = .csi_param;
            if (self.param_count == 0) self.param_count = 1;
            if (self.param_count < 16) self.param_count += 1;
            return null;
        }
        if (byte == '?' or byte == '>' or byte == '<' or byte == '=') {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .csi_param;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .csi_intermediate;
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7e) return self.dispatchCsi(byte);
        self.state = .csi_ignore;
        return null;
    }

    fn handleCsiParam(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= '0' and byte <= '9') {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            return null;
        }
        if (byte == ';') {
            if (self.param_count < 16) self.param_count += 1;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .csi_intermediate;
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7e) return self.dispatchCsi(byte);
        self.state = .csi_ignore;
        return null;
    }

    fn handleCsiIntermediate(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7e) return self.dispatchCsi(byte);
        self.state = .csi_ignore;
        return null;
    }

    fn handleCsiIgnore(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= 0x40 and byte <= 0x7e) self.state = .ground;
        return null;
    }

    fn dispatchCsi(self: *Parser, final: u8) InputEvent {
        const event = InputEvent{ .csi = .{
            .final = final,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .params = self.params,
            .param_count = self.param_count,
        } };
        self.state = .ground;
        return event;
    }

    fn handleOscString(self: *Parser, byte: u8) ?InputEvent {
        if (byte == 0x07 or byte == 0x9c) return self.dispatchOsc();
        if (byte == 0x1b) {
            self.state = .osc_escape;
            return null;
        }
        if (!self.osc_ps_done) {
            if (byte >= '0' and byte <= '9') {
                self.osc_ps = self.osc_ps *| 10 +| (byte - '0');
                return null;
            }
            if (byte == ';') {
                self.osc_ps_done = true;
                return null;
            }
        }
        if (self.osc_len < self.osc_buf.len) {
            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }
        return null;
    }

    fn handleOscEscape(self: *Parser, byte: u8) ?InputEvent {
        if (byte == '\\') return self.dispatchOsc();
        self.state = .osc_string;
        self.appendOscByte(0x1b);
        return self.handleOscString(byte);
    }

    fn handleOscSt(self: *Parser, byte: u8) ?InputEvent {
        self.st_escape_pending = false;
        if (byte == '\\') return self.dispatchOsc();
        self.appendOscByte(0x1b);
        return self.handleOscString(byte);
    }

    fn dispatchOsc(self: *Parser) InputEvent {
        var osc = OSC{ .ps = self.osc_ps };
        const len = @min(self.osc_len, @as(u16, @intCast(osc.data.len)));
        @memcpy(osc.data[0..len], self.osc_buf[0..len]);
        osc.data_len = len;
        self.st_escape_pending = false;
        self.state = .ground;
        return .{ .osc = osc };
    }

    fn handleDcsEntry(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= '0' and byte <= '9') {
            self.state = .dcs_param;
            if (self.param_count == 0) self.param_count = 1;
            self.params[self.param_count - 1] = byte - '0';
            return null;
        }
        if (byte == ';') {
            self.state = .dcs_param;
            if (self.param_count < 16) self.param_count += 1;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) {
            if (self.intermediate_count < 4) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .dcs_intermediate;
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7e) {
            self.dcs_final = byte;
            self.state = .dcs_passthrough;
            return null;
        }
        self.state = .dcs_ignore;
        return null;
    }

    fn handleDcsParam(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= '0' and byte <= '9') {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            return null;
        }
        if (byte == ';') {
            if (self.param_count < 16) self.param_count += 1;
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7e) {
            self.dcs_final = byte;
            self.state = .dcs_passthrough;
            return null;
        }
        self.state = .dcs_ignore;
        return null;
    }

    fn handleDcsIntermediate(self: *Parser, byte: u8) ?InputEvent {
        if (byte >= 0x40 and byte <= 0x7e) {
            self.dcs_final = byte;
            self.state = .dcs_passthrough;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2f) return null;
        self.state = .dcs_ignore;
        return null;
    }

    fn handleDcsPassthrough(self: *Parser, byte: u8) ?InputEvent {
        if (byte == 0x9c) return self.dispatchDcs();
        if (byte == 0x1b) {
            self.state = .dcs_escape;
            return null;
        }
        if (self.dcs_len < self.dcs_buf.len) {
            self.dcs_buf[self.dcs_len] = byte;
            self.dcs_len += 1;
        }
        return null;
    }

    fn handleDcsEscape(self: *Parser, byte: u8) ?InputEvent {
        if (byte == '\\') return self.dispatchDcs();
        self.state = .dcs_passthrough;
        self.appendDcsByte(0x1b);
        return self.handleDcsPassthrough(byte);
    }

    fn handleDcsSt(self: *Parser, byte: u8) ?InputEvent {
        self.st_escape_pending = false;
        if (byte == '\\') return self.dispatchDcs();
        self.appendDcsByte(0x1b);
        return self.handleDcsPassthrough(byte);
    }

    fn dispatchDcs(self: *Parser) InputEvent {
        var dcs = DCS{
            .final = self.dcs_final,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .params = self.params,
            .param_count = self.param_count,
        };
        const len = @min(self.dcs_len, @as(u16, @intCast(dcs.data.len)));
        @memcpy(dcs.data[0..len], self.dcs_buf[0..len]);
        dcs.data_len = len;
        self.st_escape_pending = false;
        self.state = .ground;
        return .{ .dcs = dcs };
    }

    fn resetSequence(self: *Parser) void {
        self.params = .{0} ** 16;
        self.param_count = 0;
        self.intermediates = .{ 0, 0, 0, 0 };
        self.intermediate_count = 0;
        self.st_escape_pending = false;
    }

    fn appendOscByte(self: *Parser, byte: u8) void {
        if (self.osc_len < self.osc_buf.len) {
            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }
    }

    fn appendDcsByte(self: *Parser, byte: u8) void {
        if (self.dcs_len < self.dcs_buf.len) {
            self.dcs_buf[self.dcs_len] = byte;
            self.dcs_len += 1;
        }
    }
};

test "parse printable" {
    var p = Parser.init();
    const event = p.feed('A').?;
    try std.testing.expectEqual(InputEvent{ .print = 'A' }, event);
}

test "parse C0 LF" {
    var p = Parser.init();
    const event = p.feed(0x0a).?;
    try std.testing.expectEqual(InputEvent{ .c0 = 0x0a }, event);
}

test "parse CSI sgr" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    _ = p.feed('1');
    const event = p.feed('m').?;
    switch (event) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'm'), csi.final);
            try std.testing.expectEqual(@as(u5, 1), csi.param_count);
            try std.testing.expectEqual(@as(u16, 31), csi.params[0]);
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse CSI multi params" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('1');
    _ = p.feed(';');
    _ = p.feed('2');
    const event = p.feed('H').?;
    switch (event) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'H'), csi.final);
            try std.testing.expectEqual(@as(u5, 2), csi.param_count);
            try std.testing.expectEqual(@as(u16, 1), csi.params[0]);
            try std.testing.expectEqual(@as(u16, 2), csi.params[1]);
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse OSC title" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed(']');
    _ = p.feed('0');
    _ = p.feed(';');
    for ("title") |c| _ = p.feed(c);
    const event = p.feed(0x07).?;
    switch (event) {
        .osc => |osc| {
            try std.testing.expectEqual(@as(u16, 0), osc.ps);
            try std.testing.expectEqualStrings("title", osc.getData());
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse OSC title with 7-bit ST terminator" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed(']');
    _ = p.feed('0');
    _ = p.feed(';');
    for ("title") |c| _ = p.feed(c);
    _ = p.feed(0x1b);
    const event = p.feed('\\').?;
    switch (event) {
        .osc => |osc| {
            try std.testing.expectEqual(@as(u16, 0), osc.ps);
            try std.testing.expectEqualStrings("title", osc.getData());
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse ESC M" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    const event = p.feed('M').?;
    switch (event) {
        .esc => |esc| {
            try std.testing.expectEqual(@as(u8, 'M'), esc.final);
            try std.testing.expectEqual(@as(u8, 0), esc.intermediate);
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse DCS passthrough with 7-bit ST terminator" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('P');
    _ = p.feed('q');
    for ("abc") |c| _ = p.feed(c);
    _ = p.feed(0x1b);
    const event = p.feed('\\').?;
    switch (event) {
        .dcs => |dcs| {
            try std.testing.expectEqual(@as(u8, 'q'), dcs.final);
            try std.testing.expectEqualStrings("abc", dcs.getData());
        },
        else => return error.UnexpectedEvent,
    }
}

test "parse UTF-8 2-byte" {
    var p = Parser.init();
    // U+00E9 (é) = 0xC3 0xA9
    const e1 = p.feed(0xC3);
    try std.testing.expect(e1 == null); // lead byte, accumulating
    const e2 = p.feed(0xA9).?;
    try std.testing.expectEqual(InputEvent{ .print = 0xE9 }, e2);
}

test "parse UTF-8 3-byte CJK" {
    var p = Parser.init();
    // U+4E2D (中) = 0xE4 0xB8 0xAD
    try std.testing.expect(p.feed(0xE4) == null);
    try std.testing.expect(p.feed(0xB8) == null);
    const event = p.feed(0xAD).?;
    try std.testing.expectEqual(InputEvent{ .print = 0x4E2D }, event);
}

test "parse UTF-8 4-byte emoji" {
    var p = Parser.init();
    // U+1F600 (😀) = 0xF0 0x9F 0x98 0x80
    try std.testing.expect(p.feed(0xF0) == null);
    try std.testing.expect(p.feed(0x9F) == null);
    try std.testing.expect(p.feed(0x98) == null);
    const event = p.feed(0x80).?;
    try std.testing.expectEqual(InputEvent{ .print = 0x1F600 }, event);
}

test "parse UTF-8 invalid continuation aborts" {
    var p = Parser.init();
    // Start 2-byte sequence then feed non-continuation
    try std.testing.expect(p.feed(0xC3) == null);
    // Feed ASCII instead of continuation u2014 should abort UTF-8 and process 'A'
    const event = p.feed('A').?;
    try std.testing.expectEqual(InputEvent{ .print = 'A' }, event);
}
