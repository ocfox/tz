const std = @import("std");
const testing = std.testing;
const tz = @import("tz");
const codec = tz.tl.codec;

test "encode/decode i32" {
    const allocator = testing.allocator;
    const enc = try codec.encodeAlloc(@as(i32, -42), allocator);
    defer allocator.free(enc);
    try testing.expectEqual(@as(usize, 4), enc.len);
    var r: std.Io.Reader = .fixed(enc);
    const got = try codec.decode(i32, &r, allocator);
    try testing.expectEqual(@as(i32, -42), got);
}

test "encode/decode []const u8" {
    const allocator = testing.allocator;
    const enc = try codec.encodeAlloc(@as([]const u8, "hello"), allocator);
    defer allocator.free(enc);
    try testing.expectEqual(@as(usize, 8), enc.len); // 1+5+2pad
    var r: std.Io.Reader = .fixed(enc);
    const got = try codec.decode([]const u8, &r, allocator);
    defer allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

const TestMsg = struct {
    pub const tl_id: u32 = 0x12345678;
    user_id: i64,
    message: []const u8,
    flags: codec.Flags,
    reply_id: codec.Flag(0, i32) = .none,
    silent: codec.Flag(5, void) = .none,
};

test "encode/decode struct with id and flags" {
    const allocator = testing.allocator;

    // with optional field set
    {
        const msg = TestMsg{
            .user_id = 100,
            .message = "hi",
            .flags = .{},
            .reply_id = codec.Flag(0, i32).some(42),
            .silent = .none,
        };
        const enc = try codec.encodeAlloc(msg, allocator);
        defer allocator.free(enc);
        var r: std.Io.Reader = .fixed(enc);
        const got = try codec.decode(TestMsg, &r, allocator);
        defer allocator.free(got.message);
        try testing.expectEqual(@as(i64, 100), got.user_id);
        try testing.expectEqualStrings("hi", got.message);
        try testing.expectEqual(@as(i32, 42), got.reply_id.value.?);
        try testing.expectEqual(@as(?void, null), got.silent.value);
    }

    // with no optional fields set
    {
        const msg = TestMsg{
            .user_id = 7,
            .message = "x",
            .flags = .{},
        };
        const enc = try codec.encodeAlloc(msg, allocator);
        defer allocator.free(enc);
        var r: std.Io.Reader = .fixed(enc);
        const got = try codec.decode(TestMsg, &r, allocator);
        defer allocator.free(got.message);
        try testing.expectEqual(@as(?i32, null), got.reply_id.value);
    }
}

test "encode/decode struct without id" {
    const allocator = testing.allocator;
    const Bare = struct { x: i32, y: i64 };
    const val = Bare{ .x = 3, .y = 7 };
    const enc = try codec.encodeAlloc(val, allocator);
    defer allocator.free(enc);
    try testing.expectEqual(@as(usize, 12), enc.len);
    var r: std.Io.Reader = .fixed(enc);
    const got = try codec.decode(Bare, &r, allocator);
    try testing.expectEqual(@as(i32, 3), got.x);
    try testing.expectEqual(@as(i64, 7), got.y);
}

test "encode/decode []i32 vector" {
    const allocator = testing.allocator;
    const vals = [_]i32{ 1, 2, 3 };
    const enc = try codec.encodeAlloc(@as([]const i32, &vals), allocator);
    defer allocator.free(enc);
    // Wire: CID(4) + count(4) + 3*i32(12) = 20
    try testing.expectEqual(@as(usize, 20), enc.len);
    var r: std.Io.Reader = .fixed(enc);
    const got = try codec.decode([]i32, &r, allocator);
    defer allocator.free(got);
    try testing.expectEqualSlices(i32, &vals, got);
}

const TestUnion = union(enum) {
    foo: struct {
        pub const tl_id: u32 = 0xaabb0001;
        x: i32,
    },
    bar: struct {
        pub const tl_id: u32 = 0xaabb0002;
    },
};

test "encode/decode union" {
    const allocator = testing.allocator;
    {
        const val = TestUnion{ .foo = .{ .x = 99 } };
        const enc = try codec.encodeAlloc(val, allocator);
        defer allocator.free(enc);
        // Wire: CID(4) + x(4) = 8
        try testing.expectEqual(@as(usize, 8), enc.len);
        var r: std.Io.Reader = .fixed(enc);
        const got = try codec.decode(TestUnion, &r, allocator);
        try testing.expectEqual(@as(i32, 99), got.foo.x);
    }
    {
        const val = TestUnion{ .bar = .{} };
        const enc = try codec.encodeAlloc(val, allocator);
        defer allocator.free(enc);
        try testing.expectEqual(@as(usize, 4), enc.len);
        var r: std.Io.Reader = .fixed(enc);
        const got = try codec.decode(TestUnion, &r, allocator);
        try testing.expect(got == .bar);
    }
}

test "decode unknown CID returns error" {
    const allocator = testing.allocator;
    var bad = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    var r: std.Io.Reader = .fixed(&bad);
    try testing.expectError(error.UnknownConstructor, codec.decode(TestUnion, &r, allocator));
}
