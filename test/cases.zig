pub const TestCase = enum {
    @"single-file",
    @"multiple-files",
    @"directory-structure",
    @"empty-file",
    @"binary-file",
    @"large-file",
    @"special-chars",
    @"invalid-zip",

    pub fn allocPath(test_case: TestCase, allocator: std.mem.Allocator, sub_path: []const u8) []u8 {
        return std.fmt.allocPrint(allocator, "scratch/{s}/{s}", .{ @tagName(test_case), sub_path }) catch @panic("OutOfMemory");
    }
};

const std = @import("std");
