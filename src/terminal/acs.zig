/// Alternate Character Set (ACS) mappings.
/// Maps VT100 line-drawing characters to Unicode equivalents.
pub const AcsMap = struct {
    /// Look up the Unicode codepoint for a VT100 ACS character.
    /// Input is the character after ESC ( 0 (entering ACS mode).
    pub fn lookup(ch: u8) u21 {
        return switch (ch) {
            'j' => 0x2518, // u2518 Bottom right corner
            'k' => 0x2510, // u2510 Top right corner
            'l' => 0x250C, // u250c Top left corner
            'm' => 0x2514, // u2514 Bottom left corner
            'n' => 0x253C, // u253c Cross
            'q' => 0x2500, // u2500 Horizontal line
            't' => 0x251C, // u251c Left tee
            'u' => 0x2524, // u2524 Right tee
            'v' => 0x2534, // u2534 Bottom tee
            'w' => 0x252C, // u252c Top tee
            'x' => 0x2502, // u2502 Vertical line
            'a' => 0x2592, // u2592 Checkerboard
            'f' => 0x00B0, // u00b0 Degree
            'g' => 0x00B1, // u00b1 Plus/minus
            'h' => 0x2592, // Board
            'i' => 0x2603, // Lantern (snowman)
            'o' => 0x23BA, // u23ba Scan line 1
            'p' => 0x23BB, // u23bb Scan line 3
            'r' => 0x23BC, // u23bc Scan line 7
            's' => 0x23BD, // u23bd Scan line 9
            '0' => 0x25AE, // u25ae Solid block
            '<' => 0x2264, // u2264 Less than or equal
            '>' => 0x2265, // u2265 Greater than or equal
            '~' => 0x00B7, // u00b7 Middle dot
            ',' => 0x25C0, // u25c0 Left arrow
            '+' => 0x25B6, // u25b6 Right arrow
            '.' => 0x25BC, // u25bc Down arrow
            '-' => 0x25B2, // u25b2 Up arrow
            '_' => 0x00A0, // Non-breaking space
            '`' => 0x25C6, // u25c6 Diamond
            else => ch, // Pass through unknown
        };
    }

    /// Heavy (bold) variants of box-drawing characters.
    pub fn lookupHeavy(ch: u8) u21 {
        return switch (ch) {
            'j' => 0x251B, // u251b Heavy bottom right
            'k' => 0x2513, // u2513 Heavy top right
            'l' => 0x250F, // u250f Heavy top left
            'm' => 0x2517, // u2517 Heavy bottom left
            'n' => 0x254B, // u254b Heavy cross
            'q' => 0x2501, // u2501 Heavy horizontal
            't' => 0x2523, // u2523 Heavy left tee
            'u' => 0x252B, // u252b Heavy right tee
            'v' => 0x253B, // u253b Heavy bottom tee
            'w' => 0x2533, // u2533 Heavy top tee
            'x' => 0x2503, // u2503 Heavy vertical
            else => lookup(ch),
        };
    }

    /// Double-line variants.
    pub fn lookupDouble(ch: u8) u21 {
        return switch (ch) {
            'j' => 0x255D, // u255d
            'k' => 0x2557, // u2557
            'l' => 0x2554, // u2554
            'm' => 0x255A, // u255a
            'n' => 0x256C, // u256c
            'q' => 0x2550, // u2550
            't' => 0x2560, // u2560
            'u' => 0x2563, // u2563
            'v' => 0x2569, // u2569
            'w' => 0x2566, // u2566
            'x' => 0x2551, // u2551
            else => lookup(ch),
        };
    }
};

const std = @import("std");

test "acs lookup basic" {
    try std.testing.expectEqual(@as(u21, 0x2500), AcsMap.lookup('q')); // horizontal
    try std.testing.expectEqual(@as(u21, 0x2502), AcsMap.lookup('x')); // vertical
    try std.testing.expectEqual(@as(u21, 0x250C), AcsMap.lookup('l')); // top left
}

test "acs unknown passthrough" {
    try std.testing.expectEqual(@as(u21, 'Z'), AcsMap.lookup('Z'));
}
