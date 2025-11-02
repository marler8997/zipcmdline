pub const TestCase = enum {
    @"single-file",
    @"multiple-files",
    @"directory-structure",
    @"empty-file",
    @"binary-file",
    @"large-file",
    @"special-chars",
    @"invalid-zip",
    @"buffer-stress",
};

const std = @import("std");
