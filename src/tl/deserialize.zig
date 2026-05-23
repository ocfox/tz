const std = @import("std");

pub fn int(reader: anytype) !i32 {
    return reader.takeInt(i32, .little);
}
pub fn long(reader: anytype) !i64 {
    return reader.takeInt(i64, .little);
}
pub fn int128(reader: anytype) !u128 {
    return reader.takeInt(u128, .little);
}
pub fn int256(reader: anytype) ![32]u8 {
    var buf: [32]u8 = undefined;
    try reader.readSliceAll(&buf);
    return buf;
}
pub fn bytes(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    const first = try reader.takeByte();
    if (first == 255) return error.InvalidLength;
    var len: usize = 0;
    var header_len: usize = 0;
    if (first == 254) {
        var lb: [3]u8 = undefined;
        try reader.readSliceAll(&lb);
        len = @as(usize, lb[0]) | (@as(usize, lb[1]) << 8) | (@as(usize, lb[2]) << 16);
        header_len = 4;
    } else {
        len = @as(usize, first);
        header_len = 1;
    }
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try reader.readSliceAll(buf);
    const total = header_len + len;
    const pad = (4 - (total % 4)) % 4;
    try reader.discardAll(pad);
    return buf;
}

pub fn string(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    return bytes(reader, allocator);
}
