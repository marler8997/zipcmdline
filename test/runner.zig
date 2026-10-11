pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 4) {
        std.debug.print("Usage: {s} <test-case> <zip-exe> <unzip-exe>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const test_case = std.meta.stringToEnum(TestCase, args[1]) orelse {
        std.debug.print("Unknown test case: {s}\n", .{args[1]});
        return error.UnknownTestCase;
    };

    const zip_exe = args[2];
    const unzip_exe = args[3];

    const test_path = try std.fs.path.join(allocator, &.{ "scratch", @tagName(test_case) });
    defer allocator.free(test_path);
    try std.Io.Dir.cwd().deleteTree(io, test_path);
    try std.Io.Dir.cwd().createDirPath(io, test_path);

    var clean_dir = true;
    defer if (clean_dir) std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    errdefer clean_dir = false;

    switch (test_case) {
        .@"single-file" => try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
            .{ .sub_path = "test.txt", .data = "Hello, this is a test file!\nWith multiple lines.\n" },
        }, &.{}),
        .@"multiple-files" => try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
            .{ .sub_path = "file1.txt", .data = "Content of file 1" },
            .{ .sub_path = "file2.txt", .data = "Content of file 2\nWith a second line" },
            .{ .sub_path = "file3.md", .data = "# Markdown file\n\nSome content here." },
        }, &.{}),
        .@"directory-structure" => try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
            .{ .sub_path = "root.txt", .data = "Root file" },
            .{ .sub_path = "dir1/file1.txt", .data = "File in dir1" },
            .{ .sub_path = "dir1/subdir/deep.txt", .data = "Deep file" },
            .{ .sub_path = "dir2/file2.txt", .data = "File in dir2" },
        }, &.{
            "emptydir",
            "dir3/emptydir",
            "dir4/subdir/emptydir",
        }),
        .@"empty-file" => try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
            .{ .sub_path = "empty", .data = "" },
        }, &.{}),
        .@"binary-file" => {
            var binary_data: [5000]u8 = undefined;

            {
                var prng = std.Random.DefaultPrng.init(0x12345678);
                const random = prng.random();
                random.bytes(&binary_data);
            }

            try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = "binary.dat", .data = &binary_data },
            }, &.{});
        },
        .@"large-file" => {
            const size = 5 * 1024 * 1024; // 5 MB
            const large_data = try allocator.alloc(u8, size);
            defer allocator.free(large_data);
            for (large_data, 0..) |*byte, i| {
                byte.* = @truncate(i % 256);
            }
            try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = "large.bin", .data = large_data },
            }, &.{});
        },
        .@"special-chars" => try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &if (builtin.os.tag == .windows) [_]File{
            .{ .sub_path = "file with spaces.txt", .data = "Spaces in name" },
            .{ .sub_path = "file-with-dashes.txt", .data = "Dashes in name" },
            .{ .sub_path = "file_with_underscores.txt", .data = "Underscores in name" },
        } else [_]File{
            .{ .sub_path = "file with spaces.txt", .data = "Spaces in name" },
            .{ .sub_path = "file-with-dashes.txt", .data = "Dashes in name" },
            .{ .sub_path = "file_with_underscores.txt", .data = "Underscores in name" },
            .{ .sub_path = "file'with'quotes.txt", .data = "Quotes in name" },
        }, &.{}),
        .@"invalid-zip" => {
            const invalid_path = try std.fs.path.join(allocator, &.{ test_path, "invalid.zip" });
            defer allocator.free(invalid_path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = invalid_path, .data = "This is not a valid zip file!" });
            const unzip_result = try runCommand(io, allocator, &.{ unzip_exe, invalid_path }, .{ .suppress_stderr = true });
            defer allocator.free(unzip_result.stdout);
            defer allocator.free(unzip_result.stderr);
            try std.testing.expect(!unzip_result.term.success());
        },
        .@"buffer-stress" => {
            // Test with specific patterns that could expose buffer corruption
            // if the same buffer is being used incorrectly by both readers

            const pattern_size = 4096 * 10;
            const pattern_data = try allocator.alloc(u8, pattern_size);
            defer allocator.free(pattern_data);

            {
                var prng = std.Random.DefaultPrng.init(0x12345678);
                const random = prng.random();
                random.bytes(pattern_data);
            }

            // Create multiple files with different sizes to stress the buffer
            try testFiles(io, allocator, test_path, zip_exe, unzip_exe, &[_]File{
                // Small file that fits in buffer
                .{ .sub_path = "small.dat", .data = pattern_data[0..1024] },
                // File exactly matching buffer size
                .{ .sub_path = "exact.dat", .data = pattern_data[0..4096] },
                // File slightly larger than buffer
                .{ .sub_path = "larger.dat", .data = pattern_data[0..4097] },
                // Large file requiring multiple buffer fills
                .{ .sub_path = "large.dat", .data = pattern_data },
                // Prime-sized file to avoid alignment
                .{ .sub_path = "prime.dat", .data = pattern_data[0..5003] },
            }, &.{});
        },
    }
}

const File = struct {
    sub_path: []const u8,
    data: []const u8,
};

fn testFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    test_path: []const u8,
    zip_exe: []const u8,
    unzip_exe: []const u8,
    files: []const File,
    empty_dirs: []const []const u8,
) !void {
    const files_path = try std.fs.path.join(allocator, &.{ test_path, "files" });
    defer allocator.free(files_path);
    const archive_path = try std.fs.path.join(allocator, &.{ test_path, "archive.zip" });
    defer allocator.free(archive_path);

    {
        var test_files_dir = try std.Io.Dir.cwd().createDirPathOpen(io, files_path, .{});
        defer test_files_dir.close(io);
        for (files) |file| {
            if (std.fs.path.dirname(file.sub_path)) |dir| try test_files_dir.createDirPath(io, dir);
            std.log.debug("creating file '{s}'", .{file.sub_path});
            try test_files_dir.writeFile(io, .{ .sub_path = file.sub_path, .data = file.data });
        }
        for (empty_dirs) |sub_path| {
            std.log.debug("creating empty directory '{s}'", .{sub_path});
            try test_files_dir.createDirPath(io, sub_path);
        }
    }
    {
        const result = try runCommand(io, allocator, &.{ zip_exe, archive_path, files_path }, .{});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expect(result.term.success());
    }

    try std.Io.Dir.cwd().deleteTree(io, files_path);

    {
        const result = try runCommand(io, allocator, &.{ unzip_exe, "-d", files_path, archive_path }, .{});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expect(result.term.success());
    }

    {
        var test_files_dir = try std.Io.Dir.cwd().openDir(io, files_path, .{});
        defer test_files_dir.close(io);
        for (files) |file| {
            const unzipped_content = try test_files_dir.readFileAlloc(
                io,
                file.sub_path,
                allocator,
                .unlimited,
            );
            defer allocator.free(unzipped_content);
            try std.testing.expectEqualSlices(u8, file.data, unzipped_content);
        }
        for (empty_dirs) |empty_dir| {
            var dir = try test_files_dir.openDir(io, empty_dir, .{});
            dir.close(io);
        }
    }
}

fn runCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    opt: struct { suppress_stderr: bool = false },
) !std.process.RunResult {
    switch (std_options.log_level) {
        .err, .warn, .info => {},
        .debug => {
            var stderr_buf: [1024]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
            const maybe_err: ?error{WriteFailed} = blk: {
                stderr.interface.writeAll("run:") catch |e| break :blk e;
                for (argv) |arg| {
                    stderr.interface.print(" {s}", .{arg}) catch |e| break :blk e;
                }
                stderr.interface.writeAll("\n") catch |e| break :blk e;
                stderr.interface.flush() catch |e| break :blk e;
                break :blk null;
            };
            if (maybe_err) |_| return stderr.err.?;
        },
    }

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    {
        var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
        const maybe_err: ?error{WriteFailed} = blk: {
            stdout.interface.writeAll(result.stdout) catch |e| break :blk e;
            stdout.interface.flush() catch |e| break :blk e;
            break :blk null;
        };
        if (maybe_err) |_| return stdout.err.?;
    }
    if (!opt.suppress_stderr) {
        var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
        const maybe_err: ?error{WriteFailed} = blk: {
            stderr.interface.writeAll(result.stderr) catch |e| break :blk e;
            stderr.interface.flush() catch |e| break :blk e;
            break :blk null;
        };
        if (maybe_err) |_| return stderr.err.?;
    }
    return result;
}

const std = @import("std");
const builtin = @import("builtin");
const TestCase = @import("cases.zig").TestCase;
