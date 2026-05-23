pub fn int(writer: anytype, value: i32) !void {
    try writer.writeInt(i32, value, .little);
}
pub fn long(writer: anytype, value: i64) !void {
    try writer.writeInt(i64, value, .little);
}
pub fn int128(writer: anytype, value: u128) !void {
    try writer.writeInt(u128, value, .little);
}
pub fn int256(writer: anytype, value: [32]u8) !void {
    try writer.writeAll(&value);
}
pub fn bytes(writer: anytype, data: []const u8) !void {
    const len = data.len;
    if (len <= 253) {
        try writer.writeByte(@intCast(len));
        try writer.writeAll(data);
        const pad = (4 - ((len + 1) % 4)) % 4;
        try writer.splatByteAll(0, pad);
    } else {
        try writer.writeByte(254);
        try writer.writeByte(@intCast(len & 0xff));
        try writer.writeByte(@intCast((len >> 8) & 0xff));
        try writer.writeByte(@intCast((len >> 16) & 0xff));
        try writer.writeAll(data);
        const pad = (4 - (len % 4)) % 4;
        try writer.splatByteAll(0, pad);
    }
}
pub fn string(writer: anytype, s: []const u8) !void {
    return bytes(writer, s);
}
