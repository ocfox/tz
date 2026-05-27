const std = @import("std");

pub const write = struct {
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
};

pub const read = struct {
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
};
