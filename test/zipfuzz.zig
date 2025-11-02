pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // no need to free args

    if (all_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: zipfuzz ZIP_EXE UNZIP_EXE TEST_DIRECTORY SEED_FILE\n");
        std.process.exit(0xff);
    }

    const args = all_args[1..];
    if (args.len != 4) errExit("expected 4 cmdline args but got {}", .{args.len});

    const seed_filename = args[3];
    const paths: Paths = blk: {
        const test_root = args[2];
        break :blk .{
            .zip_exe = args[0],
            .unzip_exe = args[1],
            .test_root = test_root,
            .archive = try std.fs.path.join(arena, &.{ test_root, "archive.zip" }),
            .stage = try std.fs.path.join(arena, &.{ test_root, "stage" }),
            .unzipped = try std.fs.path.join(arena, &.{ test_root, "unzipped" }),
        };
    };

    const initial_seed: u64 = blk: {
        if (std.fs.path.dirname(seed_filename)) |d| try std.fs.cwd().makePath(d);
        var file = std.fs.cwd().openFile(seed_filename, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("no seed file '{s}' generating a new one", .{seed_filename});
                try saveSeedFile(seed_filename, 0);
                break :blk 0;
            },
            else => |e| errExit(
                "open seed file '{s}' failed with {s}",
                .{ seed_filename, @errorName(e) },
            ),
        };
        defer file.close();
        const seed = try parseSeedFile(seed_filename, file);
        std.log.info("restored seed {} from file", .{seed});
        break :blk seed;
    };

    var next_seed = initial_seed;
    while (true) {
        std.log.info("testing seed {}", .{next_seed});
        try testSeed(next_seed, &paths);
        next_seed += 1;
        try saveSeedFile(seed_filename, next_seed);
    }
}

const Paths = struct {
    zip_exe: []const u8,
    unzip_exe: []const u8,
    test_root: []const u8,
    stage: []const u8,
    archive: []const u8,
    unzipped: []const u8,
};

fn readSeedFile(seed_filename: []const u8) !u64 {
    var file = std.fs.cwd().openFile(seed_filename, .{}) catch |e| errExit(
        "open seed file '{s}' failed with {s}",
        .{ seed_filename, @errorName(e) },
    );
    defer file.close();
    return parseSeedFile(seed_filename, file);
}
fn parseSeedFile(seed_filename: []const u8, file: std.fs.File) !u64 {
    var reader = file.reader(&.{});
    var read_buf: [100]u8 = undefined;
    const content_len = try reader.interface.readSliceShort(&read_buf);
    if (content_len == read_buf.len) errExit(
        "seed file '{s}' is too long",
        .{seed_filename},
    );
    const content = std.mem.trimRight(u8, read_buf[0..content_len], "\r\n");
    return std.fmt.parseInt(u16, content, 10) catch errExit(
        "seed file content '{s}' is not an integer",
        .{content},
    );
}

fn saveSeedFile(seed_filename: []const u8, seed: u64) !void {
    std.log.info("writing seed {}", .{seed});
    {
        var file = try std.fs.cwd().createFile(seed_filename, .{});
        defer file.close();
        var seed_buf: [100]u8 = undefined;
        const seed_str = std.fmt.bufPrint(&seed_buf, "{}\n", .{seed}) catch unreachable;
        try file.writeAll(seed_str);
    }
    std.debug.assert(seed == try readSeedFile(seed_filename));
}

fn testSeed(seed: u64, paths: *const Paths) !void {
    {
        var test_dir = try std.fs.cwd().makeOpenPath(paths.test_root, .{});
        defer test_dir.close();

        test_dir.deleteFile("archive.zip") catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try test_dir.deleteTree("stage");
        try test_dir.deleteTree("unzipped");

        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        const max_size_mb = 1;
        const size = random.intRangeAtMost(u64, 0, max_size_mb * 1024 * 1024);
        std.log.debug("Generating files with seed={d} size={} bytes", .{ seed, size });

        {
            try test_dir.makeDir("stage");
            var stage_dir = try test_dir.openDir("stage", .{});
            defer stage_dir.close();

            if (size > 0) {
                var total_generated: usize = 0;
                try generateDir(random, stage_dir, size, &total_generated, 0);
                std.debug.assert(total_generated == size);
            }
        }

        var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_instance.deinit();
        const scratch = arena_instance.allocator();
        std.log.info("running zip {s} {s}", .{ paths.archive, paths.stage });
        try reportChildResult(seed, "zip", try std.process.Child.run(.{
            .allocator = scratch,
            .argv = &.{ paths.zip_exe, paths.archive, paths.stage },
        }));
        std.log.info("running unzip -d {s} {s}", .{ paths.unzipped, paths.archive });
        try reportChildResult(seed, "unzip", try std.process.Child.run(.{
            .allocator = scratch,
            .argv = &.{ paths.unzip_exe, "-d", paths.unzipped, paths.archive },
        }));
    }

    var stage_dir = try std.fs.cwd().openDir(paths.stage, .{ .iterate = true });
    defer stage_dir.close();
    var unzipped_dir = try std.fs.cwd().openDir(paths.unzipped, .{ .iterate = true });
    defer unzipped_dir.close();
    std.log.info("verifying files...", .{});
    try verifyDirsMatch(
        .{ .root = paths.stage },
        stage_dir,
        .{ .root = paths.unzipped },
        unzipped_dir,
    );
    std.log.info("seed {} success!", .{seed});
}

const PathNode = union(enum) {
    root: []const u8,
    component: struct {
        parent: *const PathNode,
        name: []const u8,
    },
    pub fn format(self: PathNode, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (self) {
            .root => |path| try writer.print("{s}", .{path}),
            .component => |c| try writer.print("{f}/{s}'", .{ c.parent, c.name }),
        }
    }
};

fn verifyDirsMatch(
    stage_path_node: PathNode,
    stage_dir: std.fs.Dir,
    unzipped_path_node: PathNode,
    unzipped_dir: std.fs.Dir,
) !void {
    var stage_iter = stage_dir.iterate();
    var unzipped_iter = unzipped_dir.iterate();

    // First pass: iterate stage and verify each entry exists in unzipped
    while (try stage_iter.next()) |entry| switch (entry.kind) {
        .file => try verifyFile(stage_path_node, stage_dir, unzipped_dir, entry.name),
        .directory => {
            var stage_subdir = try stage_dir.openDir(entry.name, .{ .iterate = true });
            defer stage_subdir.close();
            var unzipped_subdir = unzipped_dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                else => |e| return e,
            };
            defer unzipped_subdir.close();
            try verifyDirsMatch(
                .{ .component = .{
                    .parent = &stage_path_node,
                    .name = entry.name,
                } },
                stage_subdir,
                .{ .component = .{
                    .parent = &unzipped_path_node,
                    .name = entry.name,
                } },
                unzipped_subdir,
            );
        },
        else => |kind| std.debug.panic(
            "unsupported file kind '{t}' '{f}/{s}'",
            .{ kind, stage_path_node, entry.name },
        ),
    };

    // Second pass: verify no extra entries in unzipped
    unzipped_iter = unzipped_dir.iterate();
    while (try unzipped_iter.next()) |entry| switch (entry.kind) {
        .file => {
            const stat = stage_dir.statFile(entry.name) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err(
                        "file '{f}/{s}' exists in unzipped but not in stage",
                        .{ unzipped_path_node, entry.name },
                    );
                    return err;
                },
                else => |e| return e,
            };
            std.debug.assert(stat.kind == .file);
        },
        .directory => {
            var dir = stage_dir.openDir(entry.name, .{}) catch |err| switch (err) {
                else => |e| return e,
            };
            dir.close();
        },
        else => |kind| std.debug.panic(
            "unsupported file kind '{t}' '{f}/{s}'",
            .{ kind, unzipped_path_node, entry.name },
        ),
    };
}

fn verifyFile(
    path_node: PathNode,
    stage_dir: std.fs.Dir,
    unzipped_dir: std.fs.Dir,
    name: []const u8,
) !void {
    const stage_file = try stage_dir.openFile(name, .{});
    defer stage_file.close();
    const unzipped_file = try unzipped_dir.openFile(name, .{});
    defer unzipped_file.close();

    const stage_stat = try stage_file.stat();
    const unzipped_stat = try unzipped_file.stat();

    if (stage_stat.size != unzipped_stat.size) errExit(
        "size mismatch for '{f}/{s}': stage has {} bytes, unzipped has {} bytes",
        .{ path_node, name, stage_stat.size, unzipped_stat.size },
    );

    var stage_reader = stage_file.reader(&.{});
    var unzipped_reader = unzipped_file.reader(&.{});

    {
        const buf_size = 4096;
        var buf1: [buf_size]u8 = undefined;
        var buf2: [buf_size]u8 = undefined;
        var offset: u64 = 0;

        while (offset < stage_stat.size) {
            const read_size = @min(buf_size, stage_stat.size - offset);
            try stage_reader.interface.readSliceAll(buf1[0..read_size]);
            try unzipped_reader.interface.readSliceAll(buf2[0..read_size]);
            if (!std.mem.eql(u8, buf1[0..read_size], buf2[0..read_size])) errExit(
                "content mismatch for '{f}/{s}' at offset {}",
                .{ path_node, name, offset },
            );
            offset += read_size;
        }
    }

    {
        var buf: [1]u8 = undefined;
        const stage_extra = try stage_reader.interface.readSliceShort(&buf);
        if (stage_extra != 0) errExit(
            "stage file '{f}/{s}' has extra data after expected {} bytes",
            .{ path_node, name, stage_stat.size },
        );
    }
    {
        var buf: [1]u8 = undefined;
        const unzipped_extra = try unzipped_reader.interface.readSliceShort(&buf);
        if (unzipped_extra != 0) errExit(
            "unzipped file '{f}/{s}' has extra data after expected {} bytes",
            .{ path_node, name, unzipped_stat.size },
        );
    }
}

fn reportChildResult(seed: u64, name: []const u8, result: std.process.Child.RunResult) !void {
    if (result.stdout.len > 0) std.log.info(
        "{s} stdout: {} bytes:\n---\n{s}\n---\n",
        .{ name, result.stdout.len, result.stdout },
    ) else std.log.info("{s} stdout: empty", .{name});
    if (result.stderr.len > 0) std.log.info(
        "{s} stderr: {} bytes:\n---\n{s}\n---\n",
        .{ name, result.stderr.len, result.stderr },
    ) else std.log.info("{s} stderr: empty", .{name});
    switch (result.term) {
        .Exited => |code| if (code != 0) errExit(
            "seed {}: {s} exited with code {}",
            .{ seed, name, code },
        ),
        inline else => |sig, tag| errExit(
            "seed {}: {s} terminated from {s} ({})",
            .{ seed, name, @tagName(tag), sig },
        ),
    }
    std.log.info("{s} success", .{name});
}

const max_depth = 5;
const max_name = 100;
const max_dir_entry_count = 1000;

fn generateDir(
    random: std.Random,
    dir: std.fs.Dir,
    target_size: usize,
    current_size: *usize,
    depth: u32,
) !void {
    std.debug.assert(current_size.* < target_size);
    std.debug.assert(depth <= max_depth);

    var entry_count: u16 = 0;
    // TODO: create an algorithm that will generate a unique name for
    // ever name index value
    var name_index: u16 = random.int(u16);

    while (current_size.* != target_size and entry_count < max_dir_entry_count) : (entry_count += 1) {
        var name_buf: [100]u8 = undefined;
        const name = generateFileName(&name_buf, name_index);
        name_index +%= 1;

        const Choice = enum {
            file,
            dir,
            ret,
        };
        const choice: Choice = switch (depth) {
            0 => switch (random.enumValue(enum { file, dir })) {
                .file => .file,
                .dir => .dir,
            },
            max_depth => switch (random.enumValue(enum { file, ret })) {
                .file => .file,
                .ret => .ret,
            },
            else => random.enumValue(Choice),
        };
        switch (choice) {
            .file => {
                const max_size_mb = 10;
                const max_size = @min(max_size_mb * 1024 * 1024, target_size - current_size.*);
                const size = random.intRangeAtMost(u64, 0, max_size);
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                std.log.info("generating file '{s}' with {} bytes", .{ name, size });
                try generateFile(random, dir, name, size);
                current_size.* += size;
            },
            .dir => {
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                std.log.info("generating directory '{s}' depth {}", .{ name, depth + 1 });
                try dir.makeDir(name);
                var child_dir = try dir.openDir(name, .{});
                defer child_dir.close();
                try generateDir(random, child_dir, target_size, current_size, depth + 1);
            },
            .ret => {
                std.debug.assert(depth != 0);
                return;
            },
        }
    }
}

fn generateFileName(name_buf: *[max_name]u8, name_index: u16) []const u8 {
    // Valid filename characters for zip files (cross-platform safe)
    // Avoiding: / \ : * ? " < > | (reserved on Windows)
    // Avoiding: null and control characters
    const alphabet =
        "0123456789" ++
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
        "abcdefghijklmnopqrstuvwxyz" ++
        "!#$%&'()+,-.;=@[]^_`{}~ ";
    var remaining = name_index;
    var name_len: usize = 1;
    var bucket_size: usize = alphabet.len;

    // Find which length bucket we're in
    while (remaining >= bucket_size and name_len < max_name) {
        remaining -= @intCast(bucket_size);
        name_len += 1;
        bucket_size *= alphabet.len;
    }

    // Now 'remaining' is the index within this length bucket
    // Convert it to base-N representation with exactly 'name_len' digits
    var pos: usize = name_len;
    var value = remaining;

    while (pos > 0) {
        pos -= 1;
        name_buf[pos] = alphabet[value % alphabet.len];
        value /= alphabet.len;
    }

    const name = name_buf[0..name_len];
    if (std.mem.eql(u8, name, ".")) return "the-reserved-dot-character";
    if (std.mem.eql(u8, name, "..")) return "the-reserved-dot-dot-character";
    return name;
}

fn generateFile(random: std.Random, dir: std.fs.Dir, name: []const u8, size: u64) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    var writer = file.writer(&.{});
    var remaining: u64 = size;
    while (remaining != 0) {
        var write_buf: [4096]u8 = undefined;
        const write = write_buf[0..@min(remaining, write_buf.len)];
        random.bytes(write);
        writer.interface.writeAll(write) catch return writer.err orelse error.Unexpected;
        remaining -= write.len;
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
