const std = @import("std");
const enc = @import("encode.zig");
const dec = @import("decode.zig");
const flags = @import("flags.zig");

pub const wire = @import("wire.zig");
pub const serialize = wire.write;
pub const deserialize = wire.read;

pub const encodeAlloc = enc.encodeAlloc;
pub const encode = enc.encode;
pub const initRandom = enc.initRandom;
pub const nextRandomId = enc.nextRandomId;

pub const decode = dec.decode;
pub const decodeStructBody = dec.decodeStructBody;
pub const free = @import("free.zig").free;

pub const Flags = flags.Flags;
pub const Flags2 = flags.Flags2;
pub const BareVector = flags.BareVector;
pub const Flag = flags.Flag;
pub const Flag2 = flags.Flag2;
pub const isFlag = flags.isFlag;
pub const isFlags = flags.isFlags;
pub const isFlags2 = flags.isFlags2;

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

test "bare vector of bare structs roundtrips and matches future_salts layout" {
    const a = std.testing.allocator;
    const Salt = struct {
        pub const cid: u32 = 0x0949d9dc;
        valid_since: i32,
        valid_until: i32,
        salt: i64,
    };
    const Salts = struct {
        pub const cid: u32 = 0xae500895;
        req_msg_id: i64,
        now: i32,
        salts: BareVector(Salt),
    };
    const val = Salts{
        .req_msg_id = 123,
        .now = 1000,
        .salts = .{ .items = &.{
            .{ .valid_since = 1, .valid_until = 2, .salt = 111 },
            .{ .valid_since = 3, .valid_until = 4, .salt = 222 },
        } },
    };
    const bytes = try encodeAlloc(val, a);
    defer a.free(bytes);

    // Wire: cid(4) req_msg_id(8) now(4) count(4) + 2*16 — no 0x1cb5c415, no per-elem cid.
    try std.testing.expectEqual(@as(usize, 4 + 8 + 4 + 4 + 2 * 16), bytes.len);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[16..20], .little));

    var r = std.Io.Reader.fixed(bytes);
    const got = try decode(Salts, &r, a);
    defer free(Salts, got, a);
    try std.testing.expectEqual(@as(usize, 2), got.salts.items.len);
    try std.testing.expectEqual(@as(i64, 222), got.salts.items[1].salt);
}
