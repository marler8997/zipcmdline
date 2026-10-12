const builtin = @import("builtin");
const std = @import("std");
const TestCase = @import("test/cases.zig").TestCase;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
        },
    }).module("std");
    const zip_exe = addExe(b, patched_std, target, optimize, .zip);
    const unzip_exe = addExe(b, patched_std, target, optimize, .unzip);

    const host_zip_exe = b.addExecutable(.{
        .name = "zip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zip.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    });

    const test_step = b.step("test", "Run all tests");
    addTests(b, zip_exe, unzip_exe, test_step);

    {
        const zipfuzz_exe = b.addExecutable(.{
            .name = "zipfuzz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/zipfuzz.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install = b.addInstallArtifact(zipfuzz_exe, .{});

        const run = b.addRunArtifact(zipfuzz_exe);
        run.step.dependOn(&install.step);
        run.addArtifactArg2(zip_exe, .{});
        run.addArtifactArg2(unzip_exe, .{});
        run.addDirectoryArg2(b.path("scratch/fuzz"), .{});
        run.addFileArg(b.path(b.fmt("seeds/{t}-{t}-{t}", .{
            builtin.os.tag,
            target.result.os.tag,
            optimize,
        })));
        b.step("fuzz", "run the fuzz tester").dependOn(&run.step);
    }

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
    try ci(b, patched_std, ci_step, host_zip_exe);
}

fn addExe(
    b: *std.Build,
    patched_std: *std.Build.Module,
    target: anytype,
    optimize: anytype,
    comptime kind: enum { zip, unzip },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = @tagName(kind),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/" ++ @tagName(kind) ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step(@tagName(kind), "Run " ++ @tagName(kind));
    run_step.dependOn(&run_cmd.step);
    return exe;
}

fn addTests(
    b: *std.Build,
    zip_exe: *std.Build.Step.Compile,
    unzip_exe: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
) void {
    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/runner.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    inline for (comptime std.meta.tags(TestCase)) |case| {
        const run = b.addRunArtifact(test_runner);
        run.setName(@tagName(case));
        run.addArg(@tagName(case));
        run.addArtifactArg2(zip_exe, .{});
        run.addArtifactArg2(unzip_exe, .{});
        run.expectExitCode(0);
        test_step.dependOn(&run.step);
        b.step("test-" ++ @tagName(case), "").dependOn(&run.step);
    }
}

fn ci(
    b: *std.Build,
    patched_std: *std.Build.Module,
    ci_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const ci_targets = [_][]const u8{
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
        "aarch64-linux",
        "aarch64-macos",
        "aarch64-windows",
        "arm-linux",
        "riscv64-linux",
        "powerpc-linux",
        "powerpc64le-linux",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    ci_step.dependOn(make_archive_step);

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));
        const optimize: std.lang.Optimize = .safe;
        const zip_exe = b.addExecutable(.{
            .name = "zip",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zip.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "std", .module = patched_std }},
            }),
        });
        const unzip_exe = b.addExecutable(.{
            .name = "unzip",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/unzip.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "std", .module = patched_std }},
            }),
        });
        const zip_exe_install = b.addInstallArtifact(zip_exe, .{
            .dest_dir = .{ .override = .{ .custom = ci_target_str } },
        });
        const unzip_exe_install = b.addInstallArtifact(unzip_exe, .{
            .dest_dir = .{ .override = .{ .custom = ci_target_str } },
        });
        ci_step.dependOn(&zip_exe_install.step);
        ci_step.dependOn(&unzip_exe_install.step);

        make_archive_step.dependOn(makeCiArchiveStep(
            b,
            ci_target_str,
            target.result,
            zip_exe,
            unzip_exe,
            host_zip_exe,
        ));
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    ci_target_str: []const u8,
    target: std.Target,
    zip_exe: *std.Build.Step.Compile,
    unzip_exe: *std.Build.Step.Compile,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    // stage the files so the archive has no parent path
    const stage = b.addWriteFiles();
    _ = stage.addCopyFile(zip_exe.getEmittedBin(), zip_exe.out_filename);
    _ = stage.addCopyFile(unzip_exe.getEmittedBin(), unzip_exe.out_filename);

    if (target.os.tag == .windows) {
        _ = stage.addCopyFile(zip_exe.getEmittedPdb(), "zip.pdb");
        _ = stage.addCopyFile(unzip_exe.getEmittedPdb(), "unzip.pdb");
        const basename = b.fmt("zipcmdline-{s}.zip", .{ci_target_str});
        const zip = b.addRunArtifact(host_zip_exe);
        const out_zip_file = zip.addOutputFileArg2(basename, .{});
        zip.addArgs(&.{ "zip.exe", "zip.pdb", "unzip.exe", "unzip.pdb" });
        zip.setCwd(stage.getDirectory());
        return &b.addInstallFile(out_zip_file, basename).step;
    }

    const basename = b.fmt("zipcmdline-{s}.tar.gz", .{ci_target_str});
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const targz = tar.addOutputFileArg2(basename, .{});
    tar.addArgs(&.{ "zip", "unzip" });
    tar.setCwd(stage.getDirectory());
    return &b.addInstallFile(targz, basename).step;
}
