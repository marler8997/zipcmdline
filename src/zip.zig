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
        stderr.interface.writeAll(
            "Usage: zip [-options] ZIP_FILE FILES/DIRS..\n",
        ) catch |e| break :blk e;
        stderr.interface.flush() catch |e| break :blk e;
        break :blk null;
    };
    if (maybe_err) |_| return stderr.err.?;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var zip_file_arg: ?[]const u8 = null;
    var path_count: usize = 0;
    // expand cmdline arguments to a list of files
    var file_entries: std.ArrayList(FileEntry) = .empty;
    var arg_it = try init.args.iterateAllocator(arena);
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-"))
            fatal("unknown cmdline option '{s}'", .{arg});
        if (zip_file_arg == null) {
            zip_file_arg = arg;
            continue;
        }
        const path = arg;
        path_count += 1;

        const kind: union(enum) { file: u64, directory: void } = blk: {
            const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
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
                => fatal("file '{s}' is an unsupported type {t}", .{ path, stat.kind }),
            }
        };
        switch (kind) {
            .directory => try scanDirectory(
                arena,
                &file_entries,
                path,
                "",
                std.Io.Dir.cwd(),
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

    if (path_count == 0) {
        try usage();
        std.process.exit(0xff);
    }
    const zip_file_path = zip_file_arg.?;

    const store = try arena.alloc(FileStore, file_entries.items.len);
    // no need to free

    {
        const zip_file = std.Io.Dir.cwd().createFile(io, zip_file_path, .{}) catch |err|
            fatal("create file '{s}' failed with {t}", .{ zip_file_path, err });
        defer zip_file.close(io);
        var file_buffer: [9]u8 = undefined;
        var file_writer = zip_file.writer(io, &file_buffer);
        try writeZip(&file_writer, file_entries.items, store);
        try file_writer.interface.flush();
    }

    // go fix up the local file headers
    {
        const zip_file = std.Io.Dir.cwd().openFile(io, zip_file_path, .{ .mode = .read_write }) catch |err|
            fatal("open file '{s}' failed with {t}", .{ zip_file_path, err });
        defer zip_file.close(io);
        var writer = zip_file.writer(io, &.{});
        for (file_entries.items, 0..) |file, i| {
            if (file.zip_path[file.zip_path.len - 1] == '/') continue;
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
    file_writer: *std.Io.File.Writer,
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
            std.debug.assert(
                @sizeOf(std.zip.LocalFileHeader) + file_entry.zip_path.len == after_file_header - file_offset,
            );
        }

        if (file_entry.zip_path[file_entry.zip_path.len - 1] == '/') {
            std.debug.assert(file_entry.size == 0);
            store[i] = .{
                .file_offset = file_offset,
                .compression = .store,
                .uncompressed_size = 0,
                .crc32 = 0,
                .compressed_size = 0,
            };
            continue;
        }

        var file = blk: {
            if (file_entry.dir) |dir| {
                var entry_dir = try std.Io.Dir.cwd().openDir(io, dir, .{});
                defer entry_dir.close(io);
                break :blk try entry_dir.openFile(io, file_entry.zip_path, .{});
            }
            break :blk try std.Io.Dir.cwd().openFile(io, file_entry.zip_path, .{});
        };
        defer file.close(io);

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
                var file_reader = file.reader(io, &read_buffer);
                var reader = file_reader.interface.hashed(std.hash.Crc32.init(), &.{});

                var compress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var compressor = std.compress.flate.Compress.init(
                    &file_writer.interface,
                    &compress_buffer,
                    .raw,
                    .best,
                ) catch |err| switch (err) {
                    error.WriteFailed => return file_writer.err.?,
                };
                const written = reader.reader.streamRemaining(&compressor.writer) catch |err| switch (err) {
                    error.ReadFailed => return file_reader.err.?,
                    error.WriteFailed => return file_writer.err.?,
                };
                std.debug.assert(written == file_entry.size);
                compressor.finish() catch |err| switch (err) {
                    error.WriteFailed => return file_writer.err.?,
                };
                const end_offset = file_writer.pos + file_writer.interface.buffered().len;
                compressed_size = end_offset - start_offset;
                crc32 = reader.hasher.final();
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

const EntryKind = enum { file, directory };

fn joinZipPath(
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
    kind: EntryKind,
) ![]const u8 {
    const sep: []const u8 = if (parent.len == 0) "" else "/";
    const suffix: []const u8 = switch (kind) {
        .file => "",
        .directory => "/",
    };
    return try std.mem.concat(allocator, u8, &.{ parent, sep, child, suffix });
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    file_entries: *std.ArrayList(FileEntry),
    top_level_dir: []const u8,
    relative_path: []const u8,
    parent_dir: std.Io.Dir,
    dir_path: []const u8,
) !void {
    var dir = try parent_dir.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const entry_kind: EntryKind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            else => |kind| fatal("unsupported file type '{t}'", .{kind}),
        };
        const zip_path = try joinZipPath(allocator, relative_path, entry.name, entry_kind);
        var free_zip_path = true;
        defer if (free_zip_path) allocator.free(zip_path);
        if (isBadFilename(zip_path))
            fatal("filename '{s}' is invalid for zip files", .{zip_path});

        switch (entry_kind) {
            .directory => {
                const entry_count_before = file_entries.items.len;
                try scanDirectory(
                    allocator,
                    file_entries,
                    top_level_dir,
                    zip_path[0 .. zip_path.len - 1],
                    dir,
                    entry.name,
                );
                if (entry_count_before == file_entries.items.len) {
                    try file_entries.ensureUnusedCapacity(allocator, 1);
                    free_zip_path = false;
                    file_entries.appendAssumeCapacity(.{
                        .dir = top_level_dir,
                        .zip_path = zip_path,
                        .size = 0,
                    });
                }
            },
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                try file_entries.ensureUnusedCapacity(allocator, 1);
                free_zip_path = false;
                file_entries.appendAssumeCapacity(.{
                    .dir = top_level_dir,
                    .zip_path = zip_path,
                    .size = stat.size,
                });
            },
        }
    }
}

fn isBadFilename(filename: []const u8) bool {
    if (std.mem.findScalar(u8, filename, '\\')) |_|
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
