const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const codec = b.createModule(.{
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

    const tl_types = b.createModule(.{
        .root_source_file = gen_dir.path(b, "types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tl_codec", .module = codec },
        },
    });
    const tl_functions = b.createModule(.{
        .root_source_file = gen_dir.path(b, "functions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tl_codec", .module = codec },
            .{ .name = "tl_types", .module = tl_types },
        },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tl_codec", .module = codec },
            .{ .name = "tl_types", .module = tl_types },
            .{ .name = "tl_functions", .module = tl_functions },
        },
    });

    const lib = b.addLibrary(.{
        .name = "tz",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // tests
    const test_step = b.step("test", "Run tests");

    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    for (&[_][]const u8{ "test/tl_test.zig", "test/codec_test.zig", "test/transport_test.zig" }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "tz", .module = mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    if (b.option(bool, "integration", "Run integration tests (needs network)") orelse false) {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "tz", .module = mod }},
                .link_libc = true,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // examples
    const echo_bot = b.addExecutable(.{
        .name = "echo_bot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_bot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tz", .module = mod }},
            .link_libc = true,
        }),
    });
    b.installArtifact(echo_bot);
    const run_echo_bot = b.addRunArtifact(echo_bot);
    if (b.args) |args| run_echo_bot.addArgs(args);
    b.step("echo-bot", "Run echo_bot example").dependOn(&run_echo_bot.step);

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
