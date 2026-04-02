const std = @import("std");
const colour = @import("../core/colour.zig");

pub const Colour = colour.Colour;

/// Scope at which an option is applied.
pub const OptionScope = enum {
    server,
    session,
    window,
    pane,
};

/// Type tag for option values.
pub const OptionType = enum {
    string,
    number,
    boolean,
    colour,
    style,
};

/// Terminal style: foreground colour, background colour, and attributes.
pub const Style = struct {
    fg: Colour = .default,
    bg: Colour = .default,
    attrs: colour.Attributes = .none,
};

/// A typed option value.
pub const OptionValue = union(OptionType) {
    string: []const u8,
    number: i64,
    boolean: bool,
    colour: Colour,
    style: Style,
};

/// Static definition of an option: name, scope, type, and default value.
pub const OptionDef = struct {
    name: []const u8,
    scope: OptionScope,
    option_type: OptionType,
    default_value: OptionValue,
};

/// Per-scope storage for option values with inheritance.
///
/// Inheritance order (lowest to highest priority):
///   server <- session <- window <- pane
///
/// get() starts at the requested scope and walks up toward server,
/// returning the first value found.
pub const OptionsStore = struct {
    server: std.StringHashMap(OptionValue),
    session: std.StringHashMap(OptionValue),
    window: std.StringHashMap(OptionValue),
    pane: std.StringHashMap(OptionValue),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) OptionsStore {
        return .{
            .server = std.StringHashMap(OptionValue).init(alloc),
            .session = std.StringHashMap(OptionValue).init(alloc),
            .window = std.StringHashMap(OptionValue).init(alloc),
            .pane = std.StringHashMap(OptionValue).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *OptionsStore) void {
        self.server.deinit();
        self.session.deinit();
        self.window.deinit();
        self.pane.deinit();
    }

    /// Store a value at the given scope.
    pub fn set(self: *OptionsStore, scope: OptionScope, name: []const u8, value: OptionValue) !void {
        const map = self.mapForScope(scope);
        try map.put(name, value);
    }

    /// Retrieve a value, walking up the scope chain if not set at this scope.
    /// pane -> window -> session -> server
    pub fn get(self: *const OptionsStore, scope: OptionScope, name: []const u8) ?OptionValue {
        const chain = [_]OptionScope{ .pane, .window, .session, .server };
        const start: usize = switch (scope) {
            .pane => 0,
            .window => 1,
            .session => 2,
            .server => 3,
        };
        for (chain[start..]) |s| {
            const map: *const std.StringHashMap(OptionValue) = switch (s) {
                .server => &self.server,
                .session => &self.session,
                .window => &self.window,
                .pane => &self.pane,
            };
            if (map.get(name)) |v| return v;
        }
        return null;
    }

    /// Load default values from an OptionDef slice into their respective scopes.
    pub fn loadDefaults(self: *OptionsStore, defs: []const OptionDef) !void {
        for (defs) |def| {
            try self.set(def.scope, def.name, def.default_value);
        }
    }

    fn mapForScope(self: *OptionsStore, scope: OptionScope) *std.StringHashMap(OptionValue) {
        return switch (scope) {
            .server => &self.server,
            .session => &self.session,
            .window => &self.window,
            .pane => &self.pane,
        };
    }
};

test "set and get at same scope" {
    var store = OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(.session, "status", .{ .boolean = true });
    const v = store.get(.session, "status").?;
    try std.testing.expect(v.boolean == true);
}

test "get inherits from parent scope" {
    var store = OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    // Set at server scope only.
    try store.set(.server, "history-limit", .{ .number = 2000 });

    // Read at session scope — should inherit from server.
    const at_session = store.get(.session, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), at_session.number);

    // Read at window scope — should also inherit from server.
    const at_window = store.get(.window, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), at_window.number);

    // Read at pane scope — should also inherit from server.
    const at_pane = store.get(.pane, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), at_pane.number);
}

test "child scope overrides parent" {
    var store = OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(.server, "history-limit", .{ .number = 2000 });
    try store.set(.session, "history-limit", .{ .number = 5000 });

    // Session overrides server.
    const at_session = store.get(.session, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 5000), at_session.number);

    // Pane inherits from session (not server).
    const at_pane = store.get(.pane, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 5000), at_pane.number);

    // Server still has its own value.
    const at_server = store.get(.server, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), at_server.number);
}

test "missing option returns null" {
    var store = OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(store.get(.session, "nonexistent") == null);
}

test "load defaults" {
    const defs = [_]OptionDef{
        .{
            .name = "mouse",
            .scope = .session,
            .option_type = .boolean,
            .default_value = .{ .boolean = false },
        },
        .{
            .name = "base-index",
            .scope = .session,
            .option_type = .number,
            .default_value = .{ .number = 0 },
        },
    };

    var store = OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadDefaults(&defs);

    const mouse = store.get(.session, "mouse").?;
    try std.testing.expect(mouse.boolean == false);

    const base = store.get(.session, "base-index").?;
    try std.testing.expectEqual(@as(i64, 0), base.number);
}
