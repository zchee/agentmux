const std = @import("std");

/// Cross-platform stdlib I/O runtime owned by zmux.
///
/// Today this wraps `std.Io.Threaded`, which is the local stdlib backend that
/// reliably supports the Unix-domain socket control plane used by zmux on both
/// macOS and Linux.
pub const Runtime = struct {
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .threaded = std.Io.Threaded.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.threaded.deinit();
    }

    pub fn io(self: *Runtime) std.Io {
        return self.threaded.io();
    }
};

test "std_io runtime can accept a unix socket client" {
    const allocator = std.testing.allocator;

    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var path_buf: [128]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/zmux-std-io-{d}.sock",
        .{std.c.getpid()},
    );

    var c_path_buf: [128:0]u8 = undefined;
    @memcpy(c_path_buf[0..socket_path.len], socket_path);
    c_path_buf[socket_path.len] = 0;
    _ = std.c.unlink(@ptrCast(&c_path_buf));
    defer _ = std.c.unlink(@ptrCast(&c_path_buf));

    const io = runtime.io();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.Io.net.Server, thread_io: std.Io) !void {
            var stream = try listen_server.accept(thread_io);
            defer stream.close(thread_io);

            var buf: [16]u8 = undefined;
            var reader = stream.reader(thread_io, &buf);
            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("ping", msg);
        }
    }.run, .{ &server, io });
    defer accept_thread.join();

    var client = try address.connect(io);
    defer client.close(io);

    var writer_buf: [16]u8 = undefined;
    var writer = client.writer(io, &writer_buf);
    try writer.interface.writeAll("ping\n");
    try writer.interface.flush();
}
