const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Mode = enum { abridged, intermediate, padded };

pub const Transport = struct {
    stream: Io.net.Stream,
    mode: Mode,
    init_sent: bool = false,

    pub fn init(stream: Io.net.Stream, mode: Mode) Transport {
        return .{ .stream = stream, .mode = mode };
    }

    pub fn sendInit(self: *Transport, io: Io) !void {
        if (self.init_sent) return;
        self.init_sent = true;
        var buf: [64]u8 = undefined;
        var sw = self.stream.writer(io, &buf);
        const w = &sw.interface;
        switch (self.mode) {
            .abridged => try w.writeByte(0xef),
            .intermediate => try w.writeAll(&[4]u8{ 0xee, 0xee, 0xee, 0xee }),
            .padded => try w.writeAll(&[4]u8{ 0xdd, 0xdd, 0xdd, 0xdd }),
        }
        try w.flush();
    }

    pub fn writeFrame(self: *Transport, io: Io, data: []const u8) !void {
        try self.sendInit(io);
        std.debug.assert(data.len % 4 == 0);
        var buf: [256]u8 = undefined;
        var sw = self.stream.writer(io, &buf);
        const w = &sw.interface;
        switch (self.mode) {
            .abridged => {
                const words = data.len / 4;
                if (words < 127) {
                    try w.writeByte(@intCast(words));
                } else {
                    try w.writeByte(0x7f);
                    try w.writeByte(@intCast(words & 0xff));
                    try w.writeByte(@intCast((words >> 8) & 0xff));
                    try w.writeByte(@intCast((words >> 16) & 0xff));
                }
            },
            .intermediate, .padded => {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(data.len), .little);
                try w.writeAll(&len_buf);
            },
        }
        try w.writeAll(data);
        try w.flush();
    }

    pub fn readFrame(self: *Transport, io: Io, allocator: Allocator) ![]u8 {
        var buf: [256]u8 = undefined;
        var sr = self.stream.reader(io, &buf);
        const r = &sr.interface;
        const frame_len: usize = switch (self.mode) {
            .abridged => blk: {
                const first = try r.takeByte();
                if (first == 0x7f) {
                    var lb: [3]u8 = undefined;
                    try r.readSliceAll(&lb);
                    break :blk (@as(usize, lb[0]) | (@as(usize, lb[1]) << 8) | (@as(usize, lb[2]) << 16)) * 4;
                }
                break :blk @as(usize, first) * 4;
            },
            .intermediate, .padded => blk: {
                var lb: [4]u8 = undefined;
                try r.readSliceAll(&lb);
                break :blk std.mem.readInt(u32, &lb, .little);
            },
        };
        const payload = try allocator.alloc(u8, frame_len);
        errdefer allocator.free(payload);
        try r.readSliceAll(payload);
        return payload;
    }
};
