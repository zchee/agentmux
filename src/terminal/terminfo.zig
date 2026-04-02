const std = @import("std");

// Extern C declarations for ncurses/tinfo
const ti = struct {
    extern "c" fn setupterm(term: ?[*:0]const u8, fd: i32, errret: ?*i32) i32;
    extern "c" fn tigetstr(capname: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn tigetnum(capname: [*:0]const u8) i32;
    extern "c" fn tigetflag(capname: [*:0]const u8) i32;
};

/// Terminfo database interface.
pub const Terminfo = struct {
    initialized: bool,

    pub fn init(term: ?[:0]const u8) Terminfo {
        var errret: i32 = 0;
        const term_ptr: ?[*:0]const u8 = if (term) |t| t.ptr else null;
        const result = ti.setupterm(term_ptr, 1, &errret);
        return .{
            .initialized = (result == 0),
        };
    }

    /// Get a string capability.
    pub fn getString(self: *const Terminfo, cap: [:0]const u8) ?[]const u8 {
        if (!self.initialized) return null;
        const result = ti.tigetstr(cap.ptr) orelse return null;
        // tigetstr returns (char*)-1 on error
        if (@intFromPtr(result) == @as(usize, @bitCast(@as(isize, -1)))) return null;
        return std.mem.sliceTo(result, 0);
    }

    /// Get a numeric capability.
    pub fn getNum(self: *const Terminfo, cap: [:0]const u8) ?i32 {
        if (!self.initialized) return null;
        const result = ti.tigetnum(cap.ptr);
        if (result < 0) return null;
        return result;
    }

    /// Get a boolean capability.
    pub fn getFlag(self: *const Terminfo, cap: [:0]const u8) bool {
        if (!self.initialized) return false;
        return ti.tigetflag(cap.ptr) > 0;
    }

    /// Common capability names.
    pub const Cap = struct {
        // Cursor movement
        pub const cup = "cup"; // cursor_address
        pub const cub1 = "cub1"; // cursor_left
        pub const cuf1 = "cuf1"; // cursor_right
        pub const cuu1 = "cuu1"; // cursor_up
        pub const cud1 = "cud1"; // cursor_down
        pub const home = "home"; // cursor_home

        // Screen
        pub const clear = "clear"; // clear_screen
        pub const el = "el"; // clr_eol
        pub const ed = "ed"; // clr_eos
        pub const smcup = "smcup"; // enter_ca_mode (alt screen)
        pub const rmcup = "rmcup"; // exit_ca_mode

        // Attributes
        pub const bold = "bold"; // enter_bold_mode
        pub const dim = "dim"; // enter_dim_mode
        pub const sitm = "sitm"; // enter_italics_mode
        pub const smul = "smul"; // enter_underline_mode
        pub const rev = "rev"; // enter_reverse_mode
        pub const sgr0 = "sgr0"; // exit_attribute_mode

        // Colors
        pub const setaf = "setaf"; // set_a_foreground
        pub const setab = "setab"; // set_a_background
        pub const colors = "colors"; // max_colors

        // Scrolling
        pub const csr = "csr"; // change_scroll_region
        pub const ind = "ind"; // scroll_forward
        pub const ri = "ri"; // scroll_reverse

        // Numeric
        pub const cols_cap = "cols"; // columns
        pub const lines_cap = "lines"; // lines
    };
};
