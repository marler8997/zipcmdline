const std = @import("std");

pub const std_options: std.Options = .{
    .networking = false,
    .io_vtable = .threaded,
};

const io = std.Io.Threaded.global_single_threaded.io();

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage() !void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    const maybe_err: ?error{WriteFailed} = blk: {
        stderr.interface.writeAll("Usage: unzip [-d DIR] ZIP_FILE\n") catch |e| break :blk e;
        stderr.interface.flush() catch |e| break :blk e;
        break :blk null;
    };
    if (maybe_err) |_| return stderr.err.?;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();

    var cmdline_opt: struct {
        dir_arg: ?[]const u8 = null,
    } = .{};

    var zip_file_arg: ?[]const u8 = null;
    var non_option_count: usize = 0;
    var arg_it = try init.args.iterateAllocator(arena_instance.allocator());
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (zip_file_arg == null) zip_file_arg = arg;
            non_option_count += 1;
        } else if (std.mem.eql(u8, arg, "-d")) {
            cmdline_opt.dir_arg = arg_it.next() orelse
                fatal("option '{s}' requires an argument", .{arg});
        } else {
            fatal("unknown cmdline option '{s}'", .{arg});
        }
    }

    if (non_option_count != 1) {
        try usage();
        std.process.exit(0xff);
    }
    const zip_file_path = zip_file_arg.?;

    var out_dir = blk: {
        if (cmdline_opt.dir_arg) |dir| {
            break :blk std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.Io.Dir.cwd().createDirPath(io, dir);
                    break :blk try std.Io.Dir.cwd().openDir(io, dir, .{});
                },
                else => fatal("failed to open output directory '{s}' with {t}", .{ dir, err }),
            };
        }
        break :blk std.Io.Dir.cwd();
    };
    defer if (cmdline_opt.dir_arg) |_| out_dir.close(io);

    const zip_file = std.Io.Dir.cwd().openFile(io, zip_file_path, .{}) catch |err|
        fatal("open '{s}' failed with {t}", .{ zip_file_path, err });
    defer zip_file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = zip_file.reader(io, &buffer);
    try std.zip.extract(out_dir, &reader, .{
        .allow_backslashes = true,
    });
}
