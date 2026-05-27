const std = @import("std");
const Allocator = std.mem.Allocator;
const flags = @import("flags.zig");
const codec = @import("codec.zig");

/// Recursively frees every heap allocation that `decode` produced for a value of
/// type T (strings, vectors, boxed pointers). Mirrors decode.zig's type handling.
/// A no-op for types with no allocations, so it is always safe to call.
pub fn free(comptime T: type, value: T, allocator: Allocator) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"enum" => {},
        .array => |arr| {
            if (arr.child != u8) for (value) |elem| free(arr.child, elem, allocator);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child != u8) for (value) |elem| free(ptr.child, elem, allocator);
                allocator.free(value);
            },
            .one => {
                free(ptr.child, value.*, allocator);
                allocator.destroy(value);
            },
            else => {},
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (comptime flags.isFlags(field.type) or flags.isFlags2(field.type)) {
                    // bitmask word, no allocation
                } else if (comptime flags.isFlag(field.type)) {
                    if (@field(value, field.name).value) |inner|
                        free(field.type.Inner, inner, allocator);
                } else {
                    free(field.type, @field(value, field.name), allocator);
                }
            }
        },
        .@"union" => switch (value) {
            inline else => |payload| free(@TypeOf(payload), payload, allocator),
        },
        else => {},
    }
}

// std.testing.allocator catches both leaks (decode allocations not freed) and
// double-frees (free walking the type wrong), so a decode->free roundtrip on a
// type with nested allocations validates that free mirrors decode.
test "free mirrors decode for nested allocations" {
    const a = std.testing.allocator;
    const Inner = struct {
        pub const cid: u32 = 0x11111111;
        label: []const u8,
    };
    const Outer = struct {
        pub const cid: u32 = 0x22222222;
        name: []const u8,
        tags: []const []const u8,
        items: []const Inner,
    };
    const val = Outer{
        .name = "hello",
        .tags = &.{ "a", "bb", "ccc" },
        .items = &.{ .{ .label = "x" }, .{ .label = "yy" } },
    };
    const bytes = try codec.encodeAlloc(val, a);
    defer a.free(bytes);

    var r = std.Io.Reader.fixed(bytes);
    const got = try codec.decode(Outer, &r, a);
    free(Outer, got, a);
}
