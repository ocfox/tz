const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const codec_module = b.createModule(.{
        .root_source_file = b.path("src/tl/codec.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TL codegen
    const codegen_exe = b.addExecutable(.{
        .name = "tl_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.addFileArg(b.path("schema/mtproto.tl"));
    run_codegen.addFileArg(b.path("schema/api.tl"));
    const gen_dir = run_codegen.addOutputDirectoryArg("generated");

    const types_module = b.createModule(.{
        .root_source_file = gen_dir.path(b, "types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codec", .module = codec_module },
        },
    });
    const functions_module = b.createModule(.{
        .root_source_file = gen_dir.path(b, "functions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codec", .module = codec_module },
            .{ .name = "types", .module = types_module },
        },
    });

    const mod = b.addModule("tz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codec", .module = codec_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "functions", .module = functions_module },
        },
    });

    const lib = b.addLibrary(.{
        .name = "tz",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const docs_step = b.step("docs", "Generate documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // tests
    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const codec_tests = b.addTest(.{ .root_module = codec_module });
    test_step.dependOn(&b.addRunArtifact(codec_tests).step);

    // examples
    const echo_bot = b.addExecutable(.{
        .name = "echo_bot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_bot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tz", .module = mod }},
        }),
    });
    b.step("echo-bot", "Build echo_bot example").dependOn(&b.addInstallArtifact(echo_bot, .{}).step);

    const any_call = b.addExecutable(.{
        .name = "any_call",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/any_call.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tz", .module = mod }},
        }),
    });
    b.step("any-call", "Build any_call example").dependOn(&b.addInstallArtifact(any_call, .{}).step);

    const user_login = b.addExecutable(.{
        .name = "user_login",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/user_login.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tz", .module = mod },
                .{ .name = "functions", .module = functions_module },
            },
        }),
    });
    b.step("user-login", "Build user_login example").dependOn(&b.addInstallArtifact(user_login, .{}).step);

    const feature_demo = b.addExecutable(.{
        .name = "feature_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/feature_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tz", .module = mod }},
        }),
    });
    b.step("feature-demo", "Build feature_demo example").dependOn(&b.addInstallArtifact(feature_demo, .{}).step);

    // update-schema
    const update_schema = b.step("update-schema", "Fetch latest TL schemas from tdesktop");
    const base = "https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/Telegram/SourceFiles/mtproto/scheme/";
    for (&[_][2][]const u8{
        .{ base ++ "mtproto.tl", "schema/mtproto.tl" },
        .{ base ++ "api.tl", "schema/api.tl" },
    }) |pair| {
        const fetch = b.addSystemCommand(&.{ "curl", "-fsSL", pair[0], "-o", pair[1] });
        update_schema.dependOn(&fetch.step);
    }
}
