const std = @import("std");
const testing = std.testing;

test "tcp abridged frame length encoding — short" {
    // 16-byte payload → 4 words → single byte 0x04
    var out: [20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const payload: [16]u8 = .{1} ** 16;
    const words: u8 = 16 / 4;
    try w.writeByte(words);
    try w.writeAll(&payload);
    try testing.expectEqual(@as(u8, 4), out[0]);
    try testing.expectEqualSlices(u8, &payload, out[1..17]);
}

test "tcp abridged frame length encoding — large" {
    // words >= 127: 0x7f + 3-byte little-endian
    const words: usize = 200;
    var buf: [4]u8 = undefined;
    buf[0] = 0x7f;
    buf[1] = @intCast(words & 0xff);
    buf[2] = @intCast((words >> 8) & 0xff);
    buf[3] = @intCast((words >> 16) & 0xff);
    try testing.expectEqual(@as(u8, 0x7f), buf[0]);
    try testing.expectEqual(@as(u8, 200), buf[1]);
    try testing.expectEqual(@as(u8, 0), buf[2]);
}

test "tcp intermediate frame length encoding" {
    const data_len: u32 = 128;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, data_len, .little);
    try testing.expectEqual(@as(u8, 128), len_buf[0]);
    try testing.expectEqual(@as(u8, 0), len_buf[1]);
}
