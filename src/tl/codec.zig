const std = @import("std");
const enc = @import("encode.zig");
const dec = @import("decode.zig");
const flags_mod = @import("flags.zig");

pub const serialize = @import("serialize.zig");
pub const deserialize = @import("deserialize.zig");

pub const encodeAlloc = enc.encodeAlloc;
pub const encode = enc.encode;
pub const initRandom = enc.initRandom;

pub const decode = dec.decode;
pub const decodeStructBody = dec.decodeStructBody;

pub const Flags = flags_mod.Flags;
pub const Flags2 = flags_mod.Flags2;
pub const Flag = flags_mod.Flag;
pub const Flag2 = flags_mod.Flag2;
pub const isFlag = flags_mod.isFlag;
pub const isFlags = flags_mod.isFlags;
pub const isFlags2 = flags_mod.isFlags2;

test "encode/decode primitives" {
    const a = std.testing.allocator;

    {
        const bytes = try encodeAlloc(@as(i32, -42), a);
        defer a.free(bytes);
        var r = std.Io.Reader.fixed(bytes);
        try std.testing.expectEqual(@as(i32, -42), try decode(i32, &r, a));
    }
    {
        const bytes = try encodeAlloc(@as(i64, 0x1234567890abcdef), a);
        defer a.free(bytes);
        var r = std.Io.Reader.fixed(bytes);
        try std.testing.expectEqual(@as(i64, 0x1234567890abcdef), try decode(i64, &r, a));
    }
    {
        for ([_]bool{ true, false }) |v| {
            const bytes = try encodeAlloc(v, a);
            defer a.free(bytes);
            var r = std.Io.Reader.fixed(bytes);
            try std.testing.expectEqual(v, try decode(bool, &r, a));
        }
    }
}

test "encode/decode bytes short" {
    const a = std.testing.allocator;
    const bytes = try encodeAlloc(@as([]const u8, "hello"), a);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    var r = std.Io.Reader.fixed(bytes);
    const got = try decode([]const u8, &r, a);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello", got);
}

test "encode/decode bytes long" {
    const a = std.testing.allocator;
    const data = "x" ** 300;
    const bytes = try encodeAlloc(@as([]const u8, data), a);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 304), bytes.len);
    var r = std.Io.Reader.fixed(bytes);
    const got = try decode([]const u8, &r, a);
    defer a.free(got);
    try std.testing.expectEqualStrings(data, got);
}

test "encode/decode struct" {
    const a = std.testing.allocator;
    const S = struct {
        pub const cid: u32 = 0xdeadbeef;
        id: i32,
        score: i64,
    };
    const val = S{ .id = 7, .score = -1 };
    const bytes = try encodeAlloc(val, a);
    defer a.free(bytes);
    var r = std.Io.Reader.fixed(bytes);
    const got = try decode(S, &r, a);
    try std.testing.expectEqual(val.id, got.id);
    try std.testing.expectEqual(val.score, got.score);
}

test "encode/decode union" {
    const a = std.testing.allocator;
    const A = struct {
        pub const cid: u32 = 0xaaaaaaaa;
        x: i32,
    };
    const B = struct {
        pub const cid: u32 = 0xbbbbbbbb;
        y: i64,
    };
    const U = union(enum) { A: A, B: B };

    {
        const bytes = try encodeAlloc(U{ .A = .{ .x = 42 } }, a);
        defer a.free(bytes);
        var r = std.Io.Reader.fixed(bytes);
        const got = try decode(U, &r, a);
        try std.testing.expectEqual(@as(i32, 42), got.A.x);
    }
    {
        const bytes = try encodeAlloc(U{ .B = .{ .y = -999 } }, a);
        defer a.free(bytes);
        var r = std.Io.Reader.fixed(bytes);
        const got = try decode(U, &r, a);
        try std.testing.expectEqual(@as(i64, -999), got.B.y);
    }
}
