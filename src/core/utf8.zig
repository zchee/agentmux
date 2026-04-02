const std = @import("std");

/// A single Unicode codepoint with its UTF-8 encoding.
pub const Char = struct {
    /// The decoded codepoint.
    codepoint: u21,
    /// Number of bytes in the UTF-8 encoding (1-4).
    len: u3,
    /// The raw UTF-8 bytes.
    bytes: [4]u8,

    /// Width of this character for terminal display.
    /// Returns 0 for control characters, 1 for most characters,
    /// 2 for CJK and other wide characters.
    pub fn width(self: Char) u2 {
        return charWidth(self.codepoint);
    }

    pub fn slice(self: *const Char) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Decode a single UTF-8 character from the input.
/// Returns null if the input is empty or contains invalid UTF-8.
pub fn decode(input: []const u8) ?Char {
    if (input.len == 0) return null;

    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return null;
    if (input.len < len) return null;

    const cp = std.unicode.utf8Decode(input[0..len]) catch return null;

    var result: Char = .{
        .codepoint = cp,
        .len = len,
        .bytes = .{ 0, 0, 0, 0 },
    };
    @memcpy(result.bytes[0..len], input[0..len]);
    return result;
}

/// Encode a Unicode codepoint to UTF-8.
pub fn encode(codepoint: u21) ?Char {
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    const len = std.unicode.utf8Encode(codepoint, &bytes) catch return null;
    return .{
        .codepoint = codepoint,
        .len = @intCast(len),
        .bytes = bytes,
    };
}

/// Iterator over UTF-8 characters in a byte slice.
pub const Iterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .pos = 0 };
    }

    pub fn next(self: *Iterator) ?Char {
        if (self.pos >= self.bytes.len) return null;
        const ch = decode(self.bytes[self.pos..]) orelse {
            // Skip invalid byte
            self.pos += 1;
            return self.next();
        };
        self.pos += ch.len;
        return ch;
    }
};

/// Calculate the display width of a Unicode codepoint.
/// Returns 0 for control/combining, 1 for normal, 2 for wide (CJK, etc.).
pub fn charWidth(cp: u21) u2 {
    // C0/C1 control characters
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;

    // Combining characters (zero width)
    if (isCombining(cp)) return 0;

    // CJK Unified Ideographs and other wide characters
    if (isWide(cp)) return 2;

    return 1;
}

/// Calculate the display width of a UTF-8 string.
pub fn stringWidth(s: []const u8) usize {
    var w: usize = 0;
    var iter = Iterator.init(s);
    while (iter.next()) |ch| {
        w += ch.width();
    }
    return w;
}

fn isCombining(cp: u21) bool {
    // Combining Diacritical Marks
    if (cp >= 0x0300 and cp <= 0x036f) return true;
    // Combining Diacritical Marks Extended
    if (cp >= 0x1ab0 and cp <= 0x1aff) return true;
    // Combining Diacritical Marks Supplement
    if (cp >= 0x1dc0 and cp <= 0x1dff) return true;
    // Combining Diacritical Marks for Symbols
    if (cp >= 0x20d0 and cp <= 0x20ff) return true;
    // Combining Half Marks
    if (cp >= 0xfe20 and cp <= 0xfe2f) return true;
    // Variation Selectors
    if (cp >= 0xfe00 and cp <= 0xfe0f) return true;
    if (cp >= 0xe0100 and cp <= 0xe01ef) return true;
    return false;
}

fn isWide(cp: u21) bool {
    // CJK Unified Ideographs
    if (cp >= 0x4e00 and cp <= 0x9fff) return true;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4dbf) return true;
    // CJK Unified Ideographs Extension B
    if (cp >= 0x20000 and cp <= 0x2a6df) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xf900 and cp <= 0xfaff) return true;
    // Hangul Syllables
    if (cp >= 0xac00 and cp <= 0xd7af) return true;
    // Fullwidth Forms
    if (cp >= 0xff01 and cp <= 0xff60) return true;
    if (cp >= 0xffe0 and cp <= 0xffe6) return true;
    // CJK Radicals / Kangxi
    if (cp >= 0x2e80 and cp <= 0x2fdf) return true;
    // CJK Symbols and Punctuation
    if (cp >= 0x3000 and cp <= 0x303f) return true;
    // Hiragana, Katakana
    if (cp >= 0x3040 and cp <= 0x30ff) return true;
    // Katakana Phonetic Extensions
    if (cp >= 0x31f0 and cp <= 0x31ff) return true;
    // Enclosed CJK Letters and Months
    if (cp >= 0x3200 and cp <= 0x32ff) return true;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33ff) return true;
    // Emoji (most are wide)
    if (cp >= 0x1f300 and cp <= 0x1f9ff) return true;
    if (cp >= 0x1fa00 and cp <= 0x1fa6f) return true;
    if (cp >= 0x1fa70 and cp <= 0x1faff) return true;
    return false;
}

test "decode ascii" {
    const ch = decode("A").?;
    try std.testing.expectEqual(@as(u21, 'A'), ch.codepoint);
    try std.testing.expectEqual(@as(u3, 1), ch.len);
}

test "decode multibyte" {
    // U+00E9 LATIN SMALL LETTER E WITH ACUTE (2 bytes)
    const ch = decode("\xc3\xa9").?;
    try std.testing.expectEqual(@as(u21, 0xe9), ch.codepoint);
    try std.testing.expectEqual(@as(u3, 2), ch.len);
}

test "decode cjk" {
    // U+4E2D (中) - 3 bytes, width 2
    const ch = decode("\xe4\xb8\xad").?;
    try std.testing.expectEqual(@as(u21, 0x4e2d), ch.codepoint);
    try std.testing.expectEqual(@as(u3, 3), ch.len);
    try std.testing.expectEqual(@as(u2, 2), ch.width());
}

test "string width" {
    try std.testing.expectEqual(@as(usize, 5), stringWidth("hello"));
    // "中文" = 2 wide chars = width 4
    try std.testing.expectEqual(@as(usize, 4), stringWidth("\xe4\xb8\xad\xe6\x96\x87"));
}
