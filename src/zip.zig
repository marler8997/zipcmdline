const builtin = @import("builtin");
const std = @import("std");

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage() !void {
    try std.fs.File.stderr().writeAll(
        "Usage: zip [-options] ZIP_FILE FILES/DIRS..\n",
    );
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator)
else
    struct {}{};
pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            //error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..], 0..) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1..std.os.argv.len];
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const cmd_args = blk: {
        const cmd_args = cmdlineArgs();
        var arg_index: usize = 0;
        var non_option_len: usize = 0;
        while (arg_index < cmd_args.len) : (arg_index += 1) {
            const arg = std.mem.span(cmd_args[arg_index]);
            if (!std.mem.startsWith(u8, arg, "-")) {
                cmd_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk cmd_args[0..non_option_len];
    };

    if (cmd_args.len < 2) {
        try usage();
        std.process.exit(0xff);
    }
    const zip_file_arg = std.mem.span(cmd_args[0]);
    const paths_to_include = cmd_args[1..];

    // expand cmdline arguments to a list of files
    var file_entries: std.ArrayListUnmanaged(FileEntry) = .{};
    for (paths_to_include) |path_ptr| {
        const path = std.mem.span(path_ptr);

        const kind: union(enum) { file: u64, directory: void } = blk: {
            const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
                error.FileNotFound => fatal("path '{s}' is not found", .{path}),
                error.IsDir => break :blk .directory,
                else => |e| return e,
            };
            switch (stat.kind) {
                .directory => break :blk .directory,
                .file => break :blk .{ .file = stat.size },
                .sym_link => fatal("todo: symlinks", .{}),
                .block_device,
                .character_device,
                .named_pipe,
                .unix_domain_socket,
                .whiteout,
                .door,
                .event_port,
                .unknown,
                => fatal("file '{s}' is an unsupported type {s}", .{ path, @tagName(stat.kind) }),
            }
        };
        switch (kind) {
            .directory => try scanDirectory(
                arena,
                &file_entries,
                path,
                "",
                std.fs.cwd(),
                path,
            ),
            .file => |file_size| {
                if (isBadFilename(path))
                    fatal("filename '{s}' is invalid for zip files", .{path});
                try file_entries.append(arena, .{
                    .dir = null,
                    .zip_path = path,
                    .size = file_size,
                });
            },
        }
    }

    const store = try arena.alloc(FileStore, file_entries.items.len);
    // no need to free

    {
        const zip_file = std.fs.cwd().createFile(zip_file_arg, .{}) catch |err|
            fatal("create file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
        defer zip_file.close();
        var file_buffer: [9]u8 = undefined;
        var file_writer = zip_file.writer(&file_buffer);
        try writeZip(&file_writer, file_entries.items, store);
        try file_writer.interface.flush();
    }

    // go fix up the local file headers
    {
        const zip_file = std.fs.cwd().openFile(zip_file_arg, .{ .mode = .read_write }) catch |err|
            fatal("open file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
        defer zip_file.close();
        var writer = zip_file.writer(&.{});
        for (file_entries.items, 0..) |file, i| {
            try writer.seekTo(store[i].file_offset);
            const hdr: std.zip.LocalFileHeader = .{
                .signature = std.zip.local_file_header_sig,
                .version_needed_to_extract = 10,
                .flags = .{ .encrypted = false, ._ = 0 },
                .compression_method = store[i].compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = store[i].crc32,
                .compressed_size = store[i].compressed_size,
                .uncompressed_size = @intCast(file.size),
                .filename_len = @intCast(file.zip_path.len),
                .extra_len = 0,
            };
            try writer.interface.writeStruct(hdr, .little);
        }
    }
}

const FileEntry = struct {
    // the path the directory containing this file
    dir: ?[]const u8,
    // the relative path of the file in the zip archive
    zip_path: []const u8,
    size: u64,
};

fn writeZip(
    file_writer: *std.fs.File.Writer,
    file_entries: []const FileEntry,
    store: []FileStore,
) !void {
    var first_central_offset: ?u64 = null;
    var cd_count: u64 = 0;

    for (file_entries, 0..) |file_entry, i| {
        const file_offset = file_writer.pos + file_writer.interface.buffered().len;
        const compression: std.zip.CompressionMethod = .deflate;

        try writeFileHeader(&file_writer.interface, file_entry.zip_path, compression);

        {
            const after_file_header = file_writer.pos + file_writer.interface.buffered().len;
            std.debug.assert(@sizeOf(std.zip.LocalFileHeader) + file_entry.zip_path.len == after_file_header - file_offset);
        }

        var file = blk: {
            if (file_entry.dir) |dir| {
                var entry_dir = try std.fs.cwd().openDir(dir, .{});
                defer entry_dir.close();
                break :blk try entry_dir.openFile(file_entry.zip_path, .{});
            }
            break :blk try std.fs.cwd().openFile(file_entry.zip_path, .{});
        };
        defer file.close();

        var crc32: u32 = undefined;

        var compressed_size = file_entry.size;
        switch (compression) {
            .store => {
                comptime unreachable;
                // var hash = std.hash.Crc32.init();
                // var full_rw_buf: [std.mem.page_size]u8 = undefined;
                // var remaining = file_entry.size;
                // while (remaining > 0) {
                //     const buf = full_rw_buf[0..@min(remaining, full_rw_buf.len)];
                //     const read_len = try file.reader().read(buf);
                //     std.debug.assert(read_len == buf.len);
                //     hash.update(buf);
                //     try zipper.counting_writer.writer().writeAll(buf);
                //     remaining -= buf.len;
                // }
                // crc32 = hash.final();
            },
            .deflate => {
                const start_offset = file_writer.pos + file_writer.interface.buffered().len;
                var read_buffer: [4096]u8 = undefined;
                var reader = Crc32Reader.init(&read_buffer, file);

                var compress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var compressor: @import("backport").compress.flate.Compress = try .init(
                    &file_writer.interface,
                    &compress_buffer,
                    .raw,
                    .best,
                );
                const written = try reader.interface.streamRemaining(&compressor.writer);
                std.debug.assert(written == file_entry.size);
                try compressor.writer.flush();
                const end_offset = file_writer.pos + file_writer.interface.buffered().len;
                compressed_size = end_offset - start_offset;
                crc32 = reader.crc32.final();
            },
            else => @panic("codebug"),
        }
        store[i] = .{
            .file_offset = file_offset,
            .compression = compression,
            .uncompressed_size = @intCast(file_entry.size),
            .crc32 = crc32,
            .compressed_size = @intCast(compressed_size),
        };
    }
    for (file_entries, 0..) |file, i| {
        if (first_central_offset == null) {
            first_central_offset = file_writer.pos + file_writer.interface.buffered().len;
        }
        try writeCentralRecord(
            &file_writer.interface,
            store[i],
            .{
                .name = file.zip_path,
            },
        );
        cd_count += 1;
    }
    const cd_offset: u64, const cd_size: u64 = if (first_central_offset) |offset|
        .{ offset, file_writer.pos + file_writer.interface.buffered().len - offset }
    else
        .{ 0, 0 };
    try writeEndRecord(&file_writer.interface, cd_count, cd_offset, cd_size);
    try file_writer.interface.flush();
}

fn joinZipPath(
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
) ![]const u8 {
    if (parent.len == 0)
        return allocator.dupe(u8, child);
    return try std.mem.concat(allocator, u8, &.{ parent, "/", child });
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    file_entries: *std.ArrayListUnmanaged(FileEntry),
    top_level_dir: []const u8,
    relative_path: []const u8,
    parent_dir: std.fs.Dir,
    dir_path: []const u8,
) !void {
    var dir = try parent_dir.openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub_directory_path = try joinZipPath(allocator, relative_path, entry.name);
                defer allocator.free(sub_directory_path);
                try scanDirectory(
                    allocator,
                    file_entries,
                    top_level_dir,
                    sub_directory_path,
                    dir,
                    entry.name,
                );
            },
            .file => {
                const file_path = try joinZipPath(allocator, relative_path, entry.name);
                // don't free, we still need this path
                if (isBadFilename(file_path)) std.debug.panic(
                    "unexpected bad filename '{s}'",
                    .{file_path},
                );
                const stat = try dir.statFile(entry.name);
                try file_entries.append(allocator, .{
                    .dir = top_level_dir,
                    .zip_path = file_path,
                    .size = stat.size,
                });
            },
            else => |kind| fatal("unsupported file type '{s}'", .{@tagName(kind)}),
        }
    }
}

const Crc32Reader = struct {
    interface: std.Io.Reader,
    file: std.fs.File,
    crc32: std.hash.Crc32 = std.hash.Crc32.init(),

    pub fn init(buffer: []u8, file: std.fs.File) Crc32Reader {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
            .file = file,
            .crc32 = std.hash.Crc32.init(),
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .discard = discard,
        .rebase = rebase,
    };

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Crc32Reader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const n = self.file.read(dest) catch |err| switch (err) {
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        self.crc32.update(dest[0..n]);
        w.advance(n);
        return n;
    }
    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        _ = r;
        _ = limit;
        @panic("not implemented");
    }
    fn rebase(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
        _ = r;
        _ = capacity;
        @panic("not implemented");
    }
};

fn isBadFilename(filename: []const u8) bool {
    if (std.mem.indexOfScalar(u8, filename, '\\')) |_|
        return true;

    if (filename.len == 0 or filename[0] == '/' or filename[0] == '\\')
        return true;

    var it = std.mem.splitAny(u8, filename, "/" ++ "\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

// Used to store any data from writing a file to the zip archive that's needed
// when writing the corresponding central directory record.
pub const FileStore = struct {
    file_offset: u64,
    compression: std.zip.CompressionMethod,
    uncompressed_size: u32,
    crc32: u32,
    compressed_size: u32,
};

fn writeFileHeader(
    writer: *std.Io.Writer,
    name: []const u8,
    compression: std.zip.CompressionMethod,
) error{WriteFailed}!void {
    const hdr: std.zip.LocalFileHeader = .{
        .signature = std.zip.local_file_header_sig,
        .version_needed_to_extract = 10,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = compression,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = 0,
        .compressed_size = 0,
        .uncompressed_size = 0,
        .filename_len = @intCast(name.len),
        .extra_len = 0,
    };
    try writer.writeStruct(hdr, .little);
    try writer.writeAll(name);
}

fn writeCentralRecord(
    writer: *std.Io.Writer,
    store: FileStore,
    opt: struct {
        name: []const u8,
        version_needed_to_extract: u16 = 10,
    },
) error{WriteFailed}!void {
    const hdr: std.zip.CentralDirectoryFileHeader = .{
        .signature = std.zip.central_file_header_sig,
        .version_made_by = 0,
        .version_needed_to_extract = opt.version_needed_to_extract,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = store.compression,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = store.crc32,
        .compressed_size = store.compressed_size,
        .uncompressed_size = @intCast(store.uncompressed_size),
        .filename_len = @intCast(opt.name.len),
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0,
        .local_file_header_offset = @intCast(store.file_offset),
    };
    try writer.writeStruct(hdr, .little);
    try writer.writeAll(opt.name);
}

fn writeEndRecord(
    writer: *std.Io.Writer,
    cd_count: u64,
    cd_offset: u64,
    cd_size: u64,
) error{WriteFailed}!void {
    const hdr: std.zip.EndRecord = .{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(cd_count),
        .record_count_total = @intCast(cd_count),
        .central_directory_size = @intCast(cd_size),
        .central_directory_offset = @intCast(cd_offset),
        .comment_len = 0,
    };
    try writer.writeStruct(hdr, .little);
}
