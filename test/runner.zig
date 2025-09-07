pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
    try std.fs.cwd().deleteTree(test_path);
    try std.fs.cwd().makePath(test_path);

    var clean_dir = true;
    defer if (clean_dir) std.fs.cwd().deleteTree(test_path) catch {};
    errdefer clean_dir = false;

    switch (test_case) {
        .@"single-file" => {
            const test_txt = test_case.allocPath(allocator, "test.txt");
            defer allocator.free(test_txt);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = test_txt, .data = "Hello, this is a test file!\nWith multiple lines.\n" },
            });
        },
        .@"multiple-files" => {
            const files = [_]File{
                .{ .sub_path = test_case.allocPath(allocator, "file1.txt"), .data = "Content of file 1" },
                .{ .sub_path = test_case.allocPath(allocator, "file2.txt"), .data = "Content of file 2\nWith a second line" },
                .{ .sub_path = test_case.allocPath(allocator, "file3.md"), .data = "# Markdown file\n\nSome content here." },
            };
            defer for (files) |file| allocator.free(file.sub_path);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &files);
        },
        .@"directory-structure" => {
            const files = [_]File{
                .{ .sub_path = test_case.allocPath(allocator, "root.txt"), .data = "Root file" },
                .{ .sub_path = test_case.allocPath(allocator, "dir1/file1.txt"), .data = "File in dir1" },
                .{ .sub_path = test_case.allocPath(allocator, "dir1/subdir/deep.txt"), .data = "Deep file" },
                .{ .sub_path = test_case.allocPath(allocator, "dir2/file2.txt"), .data = "File in dir2" },
            };
            defer for (files) |file| allocator.free(file.sub_path);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &files);
        },
        .@"empty-file" => {
            const test_txt = test_case.allocPath(allocator, "empty");
            defer allocator.free(test_txt);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = test_txt, .data = "" },
            });
        },
        .@"binary-file" => {
            var binary_data: [5000]u8 = undefined;
            std.crypto.random.bytes(&binary_data);
            const binary_path = test_case.allocPath(allocator, "binary.dat");
            defer allocator.free(binary_path);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = binary_path, .data = &binary_data },
            });
        },
        .@"large-file" => {
            const size = 5 * 1024 * 1024; // 5 MB
            const large_data = try allocator.alloc(u8, size);
            defer allocator.free(large_data);
            for (large_data, 0..) |*byte, i| {
                byte.* = @truncate(i % 256);
            }
            const large_bin = test_case.allocPath(allocator, "large.bin");
            defer allocator.free(large_bin);
            try testFiles(allocator, test_path, zip_exe, unzip_exe, &[_]File{
                .{ .sub_path = large_bin, .data = large_data },
            });
        },
        .@"special-chars" => {
            const files = if (builtin.os.tag == .windows) [_]File{
                .{ .sub_path = test_case.allocPath(allocator, "file with spaces.txt"), .data = "Spaces in name" },
                .{ .sub_path = test_case.allocPath(allocator, "file-with-dashes.txt"), .data = "Dashes in name" },
                .{ .sub_path = test_case.allocPath(allocator, "file_with_underscores.txt"), .data = "Underscores in name" },
            } else [_]File{
                .{ .sub_path = test_case.allocPath(allocator, "file with spaces.txt"), .data = "Spaces in name" },
                .{ .sub_path = test_case.allocPath(allocator, "file-with-dashes.txt"), .data = "Dashes in name" },
                .{ .sub_path = test_case.allocPath(allocator, "file_with_underscores.txt"), .data = "Underscores in name" },
                .{ .sub_path = test_case.allocPath(allocator, "file'with'quotes.txt"), .data = "Quotes in name" },
            };
            defer for (files) |file| allocator.free(file.sub_path);

            try testFiles(allocator, test_path, zip_exe, unzip_exe, &files);
        },
        .@"invalid-zip" => {
            const invalid_path = test_case.allocPath(allocator, "invalid.zip");
            defer allocator.free(invalid_path);
            try std.fs.cwd().writeFile(.{ .sub_path = invalid_path, .data = "This is not a valid zip file!" });
            const unzip_result = try runCommand(allocator, &.{ unzip_exe, invalid_path }, .{ .suppress_stderr = true });
            defer allocator.free(unzip_result.stdout);
            defer allocator.free(unzip_result.stderr);
            try std.testing.expect(unzip_result.term != .Exited or unzip_result.term.Exited != 0);
        },
    }
}

const File = struct {
    sub_path: []const u8,
    data: []const u8,
};

fn testFiles(
    allocator: std.mem.Allocator,
    test_path: []const u8,
    zip_exe: []const u8,
    unzip_exe: []const u8,
    files: []const File,
) !void {
    for (files) |file| {
        if (std.fs.path.dirname(file.sub_path)) |dir| try std.fs.cwd().makePath(dir);
        std.log.debug("creating file '{s}'", .{file.sub_path});
        try std.fs.cwd().writeFile(.{ .sub_path = file.sub_path, .data = file.data });
    }

    const archive_zip = try std.fs.path.join(allocator, &.{ test_path, "archive.zip" });
    defer allocator.free(archive_zip);

    {
        var zip_args = std.ArrayList([]const u8).init(allocator);
        defer zip_args.deinit();
        try zip_args.append(zip_exe);
        try zip_args.append(archive_zip);
        for (files) |file| {
            try zip_args.append(file.sub_path);
        }
        const result = try runCommand(allocator, zip_args.items, .{});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    }

    for (files) |file| {
        try std.fs.cwd().deleteFile(file.sub_path);
    }

    {
        const result = try runCommand(allocator, &.{ unzip_exe, archive_zip }, .{});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    }

    for (files) |file| {
        const unzipped_content = try std.fs.cwd().readFileAlloc(allocator, file.sub_path, std.math.maxInt(usize));
        defer allocator.free(unzipped_content);
        try std.testing.expectEqualSlices(u8, file.data, unzipped_content);
    }
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, opt: struct {
    suppress_stderr: bool = false,
}) !std.process.Child.RunResult {
    switch (std_options.log_level) {
        .err, .warn, .info => {},
        .debug => {
            var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
            try bw.writer().writeAll("run:");
            for (argv) |arg| {
                try bw.writer().print(" {s}", .{arg});
            }
            try bw.writer().writeAll("\n");
            try bw.flush();
        },
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    try std.io.getStdOut().writer().writeAll(result.stdout);
    if (!opt.suppress_stderr) {
        try std.io.getStdErr().writer().writeAll(result.stderr);
    }
    return result;
}

const std = @import("std");
const builtin = @import("builtin");
const TestCase = @import("cases.zig").TestCase;
