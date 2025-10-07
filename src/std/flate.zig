const std = @import("std");

/// When compressing and decompressing, the provided buffer is used as the
/// history window, so it must be at least this size.
pub const max_window_len = history_len * 2;

pub const history_len = 32768;

pub const Compress = @import("flate/Compress.zig");

pub const Container = enum {
    raw, // no header or footer
    gzip, // gzip header and footer
    zlib, // zlib header and footer

    pub fn size(w: Container) usize {
        return headerSize(w) + footerSize(w);
    }

    pub fn headerSize(w: Container) usize {
        return header(w).len;
    }

    pub fn footerSize(w: Container) usize {
        return switch (w) {
            .gzip => 8,
            .zlib => 4,
            .raw => 0,
        };
    }

    pub const list = [_]Container{ .raw, .gzip, .zlib };

    pub const Error = error{
        BadGzipHeader,
        BadZlibHeader,
        WrongGzipChecksum,
        WrongGzipSize,
        WrongZlibChecksum,
    };

    pub fn header(container: Container) []const u8 {
        return switch (container) {
            // GZIP 10 byte header (https://datatracker.ietf.org/doc/html/rfc1952#page-5):
            //  - ID1 (IDentification 1), always 0x1f
            //  - ID2 (IDentification 2), always 0x8b
            //  - CM (Compression Method), always 8 = deflate
            //  - FLG (Flags), all set to 0
            //  - 4 bytes, MTIME (Modification time), not used, all set to zero
            //  - XFL (eXtra FLags), all set to zero
            //  - OS (Operating System), 03 = Unix
            .gzip => &[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 },
            // ZLIB has a two-byte header (https://datatracker.ietf.org/doc/html/rfc1950#page-4):
            // 1st byte:
            //  - First four bits is the CINFO (compression info), which is 7 for the default deflate window size.
            //  - The next four bits is the CM (compression method), which is 8 for deflate.
            // 2nd byte:
            //  - Two bits is the FLEVEL (compression level). Values are: 0=fastest, 1=fast, 2=default, 3=best.
            //  - The next bit, FDICT, is set if a dictionary is given.
            //  - The final five FCHECK bits form a mod-31 checksum.
            //
            // CINFO = 7, CM = 8, FLEVEL = 0b10, FDICT = 0, FCHECK = 0b11100
            .zlib => &[_]u8{ 0x78, 0b10_0_11100 },
            .raw => &.{},
        };
    }

    pub const Hasher = union(Container) {
        raw: void,
        gzip: struct {
            crc: std.hash.Crc32 = .init(),
            count: u32 = 0,
        },
        zlib: std.hash.Adler32,

        pub fn init(containter: Container) Hasher {
            return switch (containter) {
                .gzip => .{ .gzip = .{} },
                .zlib => .{ .zlib = .{} },
                .raw => .raw,
            };
        }

        pub fn container(h: Hasher) Container {
            return h;
        }

        pub fn update(h: *Hasher, buf: []const u8) void {
            switch (h.*) {
                .raw => {},
                .gzip => |*gzip| {
                    gzip.crc.update(buf);
                    gzip.count +%= @truncate(buf.len);
                },
                .zlib => |*zlib| {
                    zlib.update(buf);
                },
            }
        }

        pub fn writeFooter(hasher: *Hasher, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (hasher.*) {
                .gzip => |*gzip| {
                    // GZIP 8 bytes footer
                    //  - 4 bytes, CRC32 (CRC-32)
                    //  - 4 bytes, ISIZE (Input SIZE) - size of the original
                    //  (uncompressed) input data modulo 2^32
                    try writer.writeInt(u32, gzip.crc.final(), .little);
                    try writer.writeInt(u32, gzip.count, .little);
                },
                .zlib => |*zlib| {
                    // ZLIB (RFC 1950) is big-endian, unlike GZIP (RFC 1952).
                    // 4 bytes of ADLER32 (Adler-32 checksum)
                    // Checksum value of the uncompressed data (excluding any
                    // dictionary data) computed according to Adler-32
                    // algorithm.
                    try writer.writeInt(u32, zlib.adler, .big);
                },
                .raw => {},
            }
        }
    };

    pub const Metadata = union(Container) {
        raw: void,
        gzip: struct {
            crc: u32 = 0,
            count: u32 = 0,
        },
        zlib: struct {
            adler: u32 = 0,
        },

        pub fn init(containter: Container) Metadata {
            return switch (containter) {
                .gzip => .{ .gzip = .{} },
                .zlib => .{ .zlib = .{} },
                .raw => .raw,
            };
        }

        pub fn container(m: Metadata) Container {
            return m;
        }
    };
};

test {
    _ = Compress;
    // _ = Decompress;
}
