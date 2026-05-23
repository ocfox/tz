const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const meta = @import("metadata.zig");
const emit = @import("emit.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("usage: tl_gen <schema.tl>... <out_dir>", .{});
        return error.BadArgs;
    }

    var schema = parse.Schema.init();
    defer schema.deinit(allocator);

    for (args[1 .. args.len - 1]) |path| {
        try parse.parseFile(path, &schema, io, allocator, arena);
    }

    // Collect result types that have 2+ constructors — these become union types.
    var union_types = std.StringHashMap(void).init(allocator);
    defer union_types.deinit();
    {
        var counts = std.StringHashMap(u32).init(allocator);
        defer counts.deinit();
        for (schema.constructors.items) |ctor| {
            if (ctor.is_function) continue;
            const res = try counts.getOrPut(ctor.result_type);
            if (!res.found_existing) res.value_ptr.* = 0;
            res.value_ptr.* += 1;
        }
        var it = counts.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* >= 2) try union_types.put(e.key_ptr.*, {});
        }
    }

    var metadata = try meta.Metadata.init(allocator, &schema);
    defer metadata.deinit(allocator);

    const out_dir_path = args[args.len - 1];
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, out_dir_path, .default_dir);

    try emit.emitTypes(&schema, &union_types, &metadata, out_dir_path, io, allocator);
    try emit.emitFunctions(&schema, &union_types, out_dir_path, io, allocator);
}
