const std = @import("std");
const testing = std.testing;
const tz = @import("tz");
const ser = tz.tl.serialize;
const de = tz.tl.deserialize;

test "serialize/deserialize int roundtrip" {
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ser.int(&w, -42);
    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try de.int(&r);
    try testing.expectEqual(@as(i32, -42), got);
}

test "serialize/deserialize long roundtrip" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ser.long(&w, 0x0102030405060708);
    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try de.long(&r);
    try testing.expectEqual(@as(i64, 0x0102030405060708), got);
}

test "serialize/deserialize short bytes roundtrip" {
    const allocator = testing.allocator;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const data = "hello";
    try ser.bytes(&w, data);
    // padded: 1 (len) + 5 (data) + 2 (pad) = 8 bytes
    try testing.expectEqual(@as(usize, 8), w.end);
    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try de.bytes(&r, allocator);
    defer allocator.free(got);
    try testing.expectEqualSlices(u8, data, got);
}

test "serialize/deserialize long bytes roundtrip" {
    const allocator = testing.allocator;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const data = "A" ** 254;
    try ser.bytes(&w, data);
    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try de.bytes(&r, allocator);
    defer allocator.free(got);
    try testing.expectEqualSlices(u8, data, got);
}
