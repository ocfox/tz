const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const Constructor = parse.Constructor;

pub const Metadata = struct {
    // result_type -> list of constructors with that type
    defs_with_type: std.StringHashMap(std.ArrayList(Constructor)),
    // set of constructor IDs that are self-referencing (recursive)
    recursive_ids: std.AutoHashMap(u32, void),

    pub fn init(allocator: Allocator, schema: *const parse.Schema) !Metadata {
        var defs_with_type = std.StringHashMap(std.ArrayList(Constructor)).init(allocator);
        var recursive_ids = std.AutoHashMap(u32, void).init(allocator);

        for (schema.constructors.items) |ctor| {
            if (ctor.is_function) continue;
            const res = try defs_with_type.getOrPut(ctor.result_type);
            if (!res.found_existing) res.value_ptr.* = .empty;
            try res.value_ptr.append(allocator, ctor);
        }

        for (schema.constructors.items) |ctor| {
            if (ctor.is_function) continue;
            var visited = std.AutoHashMap(u32, void).init(allocator);
            defer visited.deinit();
            if (selfReferences(&ctor, &ctor, &defs_with_type, &visited)) {
                try recursive_ids.put(ctor.id, {});
            }
        }

        return .{ .defs_with_type = defs_with_type, .recursive_ids = recursive_ids };
    }

    pub fn deinit(self: *Metadata, allocator: Allocator) void {
        var it = self.defs_with_type.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        self.defs_with_type.deinit();
        self.recursive_ids.deinit();
    }

    pub fn isRecursive(self: *const Metadata, ctor: Constructor) bool {
        return self.recursive_ids.contains(ctor.id);
    }

    // Returns the constructor list for a union result type, or null.
    pub fn ctorsForType(self: *const Metadata, result_type: []const u8) ?[]Constructor {
        if (self.defs_with_type.get(result_type)) |list| return list.items;
        return null;
    }
};

// DFS: does `check` (transitively) reference `root`'s result type?
fn selfReferences(
    root: *const Constructor,
    check: *const Constructor,
    defs_with_type: *const std.StringHashMap(std.ArrayList(Constructor)),
    visited: *std.AutoHashMap(u32, void),
) bool {
    visited.put(check.id, {}) catch return false;
    for (check.params) |p| {
        if (p.is_flags) continue;
        const tname = bareTypeName(p.type_name);
        if (std.mem.eql(u8, tname, root.result_type)) return true;
        if (defs_with_type.get(tname)) |list| {
            for (list.items) |dep| {
                if (visited.contains(dep.id)) continue;
                if (selfReferences(root, &dep, defs_with_type, visited)) return true;
            }
        }
    }
    return false;
}

// Strip Vector<...> wrapper and flags?.  to get the bare type name.
fn bareTypeName(tl_type: []const u8) []const u8 {
    var t = tl_type;
    // strip optional prefix (flags.N?type already handled by parser)
    if (std.mem.indexOfScalar(u8, t, '<')) |lt| t = t[lt + 1 .. t.len - 1];
    if (std.mem.startsWith(u8, t, "Vector ")) t = t[7..];
    if (std.mem.startsWith(u8, t, "%Vector ")) t = t[8..];
    return t;
}
