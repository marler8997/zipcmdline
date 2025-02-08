const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = addExe(b, target, optimize, "zip");
    _ = addExe(b, target, optimize, "unzip");

    const host_zip_exe = b.addExecutable(.{
        .name = "zip",
        .root_source_file = b.path("src/zip.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, ci_step, host_zip_exe);
}

fn addExe(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    comptime name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step(name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);
    return exe;
}

fn ci(
    b: *std.Build,
    ci_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const ci_targets = [_][]const u8{
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
        "aarch64-linux",
        "aarch64-macos",
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
        const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
        const zip_exe = b.addExecutable(.{
            .name = "zip",
            .root_source_file = b.path("src/zip.zig"),
            .target = target,
            .optimize = optimize,
        });
        const unzip_exe = b.addExecutable(.{
            .name = "unzip",
            .root_source_file = b.path("src/unzip.zig"),
            .target = target,
            .optimize = optimize,
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
            zip_exe_install,
            unzip_exe_install,
            host_zip_exe,
        ));
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    ci_target_str: []const u8,
    target: std.Target,
    zip_exe_install: *std.Build.Step.InstallArtifact,
    unzip_exe_install: *std.Build.Step.InstallArtifact,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const install_path = b.getInstallPath(.prefix, ".");

    if (target.os.tag == .windows) {
        const out_zip_file = b.pathJoin(&.{
            install_path,
            b.fmt("zipcmdline-{s}.zip", .{ci_target_str}),
        });
        const zip = b.addRunArtifact(host_zip_exe);
        zip.addArg(out_zip_file);
        zip.addArg("zip.exe");
        zip.addArg("zip.pdb");
        zip.addArg("unzip.exe");
        zip.addArg("unzip.pdb");
        zip.cwd = .{ .cwd_relative = b.getInstallPath(
            zip_exe_install.dest_dir.?,
            ".",
        ) };
        zip.step.dependOn(&zip_exe_install.step);
        zip.step.dependOn(&unzip_exe_install.step);
        return &zip.step;
    }

    const targz = b.pathJoin(&.{
        install_path,
        b.fmt("zipcmdline-{s}.tar.gz", .{ci_target_str}),
    });
    const tar = b.addSystemCommand(&.{
        "tar",
        "-czf",
        targz,
        "zip",
        "unzip",
    });
    tar.cwd = .{ .cwd_relative = b.getInstallPath(
        zip_exe_install.dest_dir.?,
        ".",
    ) };
    tar.step.dependOn(&zip_exe_install.step);
    tar.step.dependOn(&unzip_exe_install.step);
    return &tar.step;
}
