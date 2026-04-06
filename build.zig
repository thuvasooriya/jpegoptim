const std = @import("std");
const zbh = @import("zig_build_helper");
const build_zon = @import("build.zig.zon");

comptime {
    zbh.checkZigVersion("0.15.2");
}

const sources = &[_][]const u8{
    "jpegoptim.c",
    "jpegdest.c",
    "jpegmarker.c",
    "jpegsrc.c",
    "misc.c",
    "getopt.c",
    "getopt1.c",
};

const JpegBackend = enum {
    static,
    linked,
};

fn createConfigHeader(
    b: *std.Build,
    platform: zbh.Platform,
    ptr_width: u16,
    have_arith_code: bool,
) *std.Build.Step.ConfigHeader {
    return b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .STDC_HEADERS = 1,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = @as(i32, @intCast(ptr_width / 8)),
        .HAVE_GETOPT_LONG = 1,
        .HAVE_MKSTEMPS = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_LABS = 1,
        .HAVE_FILENO = 1,
        .HAVE_UTIMENSAT = zbh.Config.boolToOptInt(platform.is_linux),
        .HAVE_FORK = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_WAIT = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_STRUCT_STAT_ST_MTIM = zbh.Config.boolToOptInt(platform.is_linux),
        .HAVE_GETOPT_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_UNISTD_H = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_LIBGEN_H = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_SYS_WAIT_H = zbh.Config.boolToOptInt(!platform.is_windows),
        .HAVE_FCNTL_H = 1,
        .HAVE_LIBJPEG = 1,
        .HAVE_ARITH_CODE = zbh.Config.boolToOptInt(have_arith_code),
        .HAVE_JINT_DC_SCAN_OPT_MODE = 0,
        .BROKEN_METHODDEF = 0,
    });
}

fn createFlags(b: *std.Build, enable_debug: bool) []const []const u8 {
    var flags = zbh.Flags.Builder.init(b.allocator);
    flags.appendSlice(&.{
        "-std=gnu89",
        "-fcommon",
        "-D_POSIX_C_SOURCE=200809L",
        "-D_DEFAULT_SOURCE",
        "-D_GNU_SOURCE",
        "-DHOST_TYPE=\"unix\"",
        "-Wno-implicit-function-declaration",
        "-Wno-int-conversion",
        "-w",
    });
    flags.appendIf(enable_debug, "-g");
    return flags.items();
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = zbh.Platform.detect(target.result);

    const upstream = b.dependency("upstream", .{});
    const enable_debug = b.option(bool, "debug", "Enable debug mode") orelse false;
    const libjpeg_backend = b.option(JpegBackend, "libjpeg", "JPEG backend: static (bundled libjpeg-turbo), linked (system libjpeg) (default: static)") orelse .static;
    const enable_arith = b.option(bool, "arith", "Enable arithmetic-coding CLI flags (default: true)") orelse true;

    const libjpeg_dep = if (libjpeg_backend == .static)
        b.dependency("libjpeg_turbo", .{ .target = target, .optimize = optimize })
    else
        null;
    const libjpeg = if (libjpeg_dep) |dep| dep.artifact("jpeg") else null;

    const config = createConfigHeader(b, platform, target.result.ptrBitWidth(), enable_arith);
    const cflags = createFlags(b, enable_debug);

    const jpegoptim = b.addExecutable(.{
        .name = "jpegoptim",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    jpegoptim.addConfigHeader(config);
    jpegoptim.addIncludePath(upstream.path(""));
    switch (libjpeg_backend) {
        .static => jpegoptim.linkLibrary(libjpeg.?),
        .linked => jpegoptim.linkSystemLibrary("jpeg"),
    }
    jpegoptim.addCSourceFiles(.{ .root = upstream.path(""), .files = sources, .flags = cflags });

    if (platform.is_windows) {
        jpegoptim.linkSystemLibrary("ws2_32");
        jpegoptim.linkSystemLibrary("advapi32");
    }

    b.installArtifact(jpegoptim);
    _ = b.addInstallFileWithDir(upstream.path("jpegoptim.1"), .{ .custom = "share/man/man1" }, "jpegoptim.1");

    // CI step
    const ci_step = b.step("ci", "Build release archives for all targets");
    const version = zbh.Dependencies.extractVersionFromUrl(build_zon.dependencies.upstream.url) orelse build_zon.version;

    const write_version = b.addWriteFiles();
    _ = write_version.add("version", version);
    ci_step.dependOn(&b.addInstallFile(write_version.getDirectory().path(b, "version"), "version").step);

    const install_path = b.getInstallPath(.prefix, ".");
    const ci_cflags = createFlags(b, false);

    for (zbh.Ci.standard) |target_str| {
        const ci_target = zbh.Ci.resolve(b, target_str);
        const ci_platform = zbh.Platform.detect(ci_target.result);

        const ci_libjpeg_dep = b.dependency("libjpeg_turbo", .{ .target = ci_target, .optimize = .ReleaseFast });
        const ci_libjpeg = ci_libjpeg_dep.artifact("jpeg");

        const ci_exe = b.addExecutable(.{
            .name = "jpegoptim",
            .root_module = b.createModule(.{
                .target = ci_target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });

        ci_exe.addConfigHeader(createConfigHeader(b, ci_platform, ci_target.result.ptrBitWidth(), true));
        ci_exe.addIncludePath(upstream.path(""));
        ci_exe.linkLibrary(ci_libjpeg);
        ci_exe.addCSourceFiles(.{ .root = upstream.path(""), .files = sources, .flags = ci_cflags });

        if (ci_platform.is_windows) {
            ci_exe.linkSystemLibrary("ws2_32");
            ci_exe.linkSystemLibrary("advapi32");
        }

        const target_archive_root: []const u8 = b.fmt("jpegoptim-{s}-{s}", .{ version, target_str });
        const target_bin_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/bin", .{target_archive_root}) };
        const target_man_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/share/man/man1", .{target_archive_root}) };
        const install = b.addInstallArtifact(ci_exe, .{ .dest_dir = .{ .override = target_bin_dir } });
        const install_man = b.addInstallFileWithDir(upstream.path("jpegoptim.1"), target_man_dir, "jpegoptim.1");

        const archive_name = target_archive_root;
        const archive = zbh.Archive.create(b, archive_name, ci_platform.is_windows, install_path);
        archive.step.dependOn(&install.step);
        archive.step.dependOn(&install_man.step);
        ci_step.dependOn(&archive.step);
    }
}
