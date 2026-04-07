const std = @import("std");

pub const ProbeKind = enum(u16) {
    osc_10 = 1,
    osc_11 = 2,
    osc_12 = 3,
    csi_primary_da = 4,
    xtversion = 5,
};

pub const ResponseStatus = enum(u8) {
    complete = 1,
    timeout = 2,
    unsupported = 3,
};

pub const PrefixMatch = enum {
    none,
    prefix,
    full,
};

pub const ReplyMatch = enum {
    invalid,
    need_more,
    complete,
};

pub fn probeKindFromInt(raw: u16) !ProbeKind {
    return switch (raw) {
        @intFromEnum(ProbeKind.osc_10) => .osc_10,
        @intFromEnum(ProbeKind.osc_11) => .osc_11,
        @intFromEnum(ProbeKind.osc_12) => .osc_12,
        @intFromEnum(ProbeKind.csi_primary_da) => .csi_primary_da,
        @intFromEnum(ProbeKind.xtversion) => .xtversion,
        else => error.InvalidProbeKind,
    };
}

pub fn responseStatusFromInt(raw: u8) !ResponseStatus {
    return switch (raw) {
        @intFromEnum(ResponseStatus.complete) => .complete,
        @intFromEnum(ResponseStatus.timeout) => .timeout,
        @intFromEnum(ResponseStatus.unsupported) => .unsupported,
        else => error.InvalidResponseStatus,
    };
}

pub fn requestBytes(kind: ProbeKind) []const u8 {
    return switch (kind) {
        .osc_10 => "\x1b]10;?\x1b\\",
        .osc_11 => "\x1b]11;?\x1b\\",
        .osc_12 => "\x1b]12;?\x1b\\",
        .csi_primary_da => "\x1b[c",
        .xtversion => "\x1b[>0q",
    };
}

pub fn requestPrefixMatch(kind: ProbeKind, bytes: []const u8) PrefixMatch {
    const request = requestBytes(kind);
    if (bytes.len > request.len) return .none;
    if (!std.mem.eql(u8, bytes, request[0..bytes.len])) return .none;
    if (bytes.len == request.len) return .full;
    return .prefix;
}

pub fn classifyReply(kind: ProbeKind, bytes: []const u8) ReplyMatch {
    return switch (kind) {
        .osc_10 => classifyOscReply("\x1b]10;", bytes),
        .osc_11 => classifyOscReply("\x1b]11;", bytes),
        .osc_12 => classifyOscReply("\x1b]12;", bytes),
        .csi_primary_da => classifyPrimaryDeviceAttributes(bytes),
        .xtversion => classifyXtVersion(bytes),
    };
}

fn classifyOscReply(prefix: []const u8, bytes: []const u8) ReplyMatch {
    if (bytes.len == 0) return .need_more;
    if (bytes.len <= prefix.len) {
        if (!std.mem.eql(u8, bytes, prefix[0..bytes.len])) return .invalid;
        return .need_more;
    }
    if (!std.mem.eql(u8, bytes[0..prefix.len], prefix)) return .invalid;
    if (bytes[bytes.len - 1] == 0x07) return .complete;
    if (bytes.len >= 2 and bytes[bytes.len - 2] == 0x1b and bytes[bytes.len - 1] == '\\') return .complete;
    return .need_more;
}

fn classifyPrimaryDeviceAttributes(bytes: []const u8) ReplyMatch {
    const prefix = "\x1b[";
    if (bytes.len == 0) return .need_more;
    if (bytes.len <= prefix.len) {
        if (!std.mem.eql(u8, bytes, prefix[0..bytes.len])) return .invalid;
        return .need_more;
    }
    if (!std.mem.eql(u8, bytes[0..prefix.len], prefix)) return .invalid;

    for (bytes[prefix.len..], 0..) |ch, idx| {
        const is_last = idx + prefix.len + 1 == bytes.len;
        if (is_last and ch == 'c') return .complete;
        if (ch == '?' or ch == ';' or (ch >= '0' and ch <= '9')) continue;
        return .invalid;
    }
    return .need_more;
}

fn classifyXtVersion(bytes: []const u8) ReplyMatch {
    const prefix = "\x1bP>|";
    if (bytes.len == 0) return .need_more;
    if (bytes.len <= prefix.len) {
        if (!std.mem.eql(u8, bytes, prefix[0..bytes.len])) return .invalid;
        return .need_more;
    }
    if (!std.mem.eql(u8, bytes[0..prefix.len], prefix)) return .invalid;
    if (bytes.len >= 2 and bytes[bytes.len - 2] == 0x1b and bytes[bytes.len - 1] == '\\') return .complete;
    return .need_more;
}

test "request prefix matching recognizes full and partial startup probes" {
    try std.testing.expectEqual(.prefix, requestPrefixMatch(.osc_10, "\x1b]10"));
    try std.testing.expectEqual(.full, requestPrefixMatch(.osc_10, requestBytes(.osc_10)));
    try std.testing.expectEqual(.none, requestPrefixMatch(.osc_10, "\x1b[31m"));
}

test "reply classification recognizes complete startup probe responses" {
    try std.testing.expectEqual(.complete, classifyReply(.osc_10, "\x1b]10;rgb:0000/0000/0000\x1b\\"));
    try std.testing.expectEqual(.complete, classifyReply(.osc_11, "\x1b]11;rgb:ffff/ffff/ffff\x07"));
    try std.testing.expectEqual(.complete, classifyReply(.csi_primary_da, "\x1b[?1;2c"));
    try std.testing.expectEqual(.complete, classifyReply(.xtversion, "\x1bP>|WezTerm 20240203\x1b\\"));
}

test "reply classification keeps partial replies open and rejects unrelated bytes" {
    try std.testing.expectEqual(.need_more, classifyReply(.osc_12, "\x1b]12;rgb:1234/5678"));
    try std.testing.expectEqual(.invalid, classifyReply(.csi_primary_da, "hello"));
    try std.testing.expectEqual(.invalid, classifyReply(.xtversion, "\x1b[>0q"));
}
