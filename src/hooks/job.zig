const std = @import("std");

/// Background job state.
pub const JobStatus = enum {
    running,
    exited,
    signaled,
};

/// A background job (run-shell, if-shell).
pub const Job = struct {
    pid: std.c.pid_t,
    read_fd: std.c.fd_t, // pipe to read stdout from child
    command: []const u8,
    status: JobStatus,
    exit_code: i32,
    output_buf: [4096]u8,
    output_len: usize,
    allocator: std.mem.Allocator,

    const pipe_fn = struct {
        extern "c" fn pipe(fds: *[2]std.c.fd_t) i32;
    };

    /// Start a background job: fork, exec "sh -c command", capture stdout.
    pub fn start(alloc: std.mem.Allocator, command: []const u8) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);

        const owned_cmd = try alloc.dupe(u8, command);
        errdefer alloc.free(owned_cmd);

        // Create pipe for capturing output
        var fds: [2]std.c.fd_t = .{ -1, -1 };
        if (pipe_fn.pipe(&fds) != 0) {
            alloc.free(owned_cmd);
            alloc.destroy(job);
            return error.PipeFailed;
        }

        const pid = std.c.fork();
        if (pid < 0) {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            alloc.free(owned_cmd);
            alloc.destroy(job);
            return error.ForkFailed;
        }

        if (pid == 0) {
            // Child: redirect stdout to pipe write end
            _ = std.c.close(fds[0]);
            _ = std.c.dup2(fds[1], 1);
            _ = std.c.dup2(fds[1], 2);
            _ = std.c.close(fds[1]);

            // Exec: sh -c command
            // Need null-terminated command string
            var cmd_buf: [4096]u8 = .{0} ** 4096;
            const copy_len = @min(command.len, cmd_buf.len - 1);
            @memcpy(cmd_buf[0..copy_len], command[0..copy_len]);
            const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..copy_len :0]);

            const sh: [*:0]const u8 = "/bin/sh";
            const c_flag: [*:0]const u8 = "-c";
            const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z };

            const execvp_fn = struct {
                extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) i32;
            };
            _ = execvp_fn.execvp(sh, &argv);
            std.c.exit(127);
        }

        // Parent
        _ = std.c.close(fds[1]);

        job.* = .{
            .pid = pid,
            .read_fd = fds[0],
            .command = owned_cmd,
            .status = .running,
            .exit_code = 0,
            .output_buf = .{0} ** 4096,
            .output_len = 0,
            .allocator = alloc,
        };
        return job;
    }

    /// Check if the job has finished (non-blocking).
    /// If finished, reads any remaining output.
    pub fn check(self: *Job) ?[]const u8 {
        // Try to read output
        if (self.read_fd >= 0 and self.output_len < self.output_buf.len) {
            const n = std.c.read(self.read_fd, self.output_buf[self.output_len..].ptr, self.output_buf.len - self.output_len);
            if (n > 0) {
                self.output_len += @intCast(n);
            }
        }

        // Check if child exited
        var wstatus: i32 = 0;
        const result = std.c.waitpid(self.pid, &wstatus, 1); // WNOHANG = 1
        if (result == self.pid) {
            self.status = .exited;
            self.exit_code = @divTrunc(wstatus, 256); // WEXITSTATUS
            // Read any remaining output
            if (self.read_fd >= 0) {
                while (self.output_len < self.output_buf.len) {
                    const n = std.c.read(self.read_fd, self.output_buf[self.output_len..].ptr, self.output_buf.len - self.output_len);
                    if (n <= 0) break;
                    self.output_len += @intCast(n);
                }
                _ = std.c.close(self.read_fd);
                self.read_fd = -1;
            }
            return self.output_buf[0..self.output_len];
        }
        return null;
    }

    /// Kill the job.
    pub fn kill(self: *Job) void {
        if (self.status == .running and self.pid > 0) {
            _ = std.c.kill(self.pid, 15); // SIGTERM
        }
    }

    /// Clean up resources.
    pub fn deinit(self: *Job) void {
        if (self.read_fd >= 0) {
            _ = std.c.close(self.read_fd);
        }
        self.allocator.free(self.command);
        self.allocator.destroy(self);
    }
};
