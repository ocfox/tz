const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const WsTransport = struct {
    stream: Io.net.Stream,

    pub fn connect(stream: Io.net.Stream, io: Io, host: []const u8, allocator: Allocator) !WsTransport {
        _ = allocator;
        var nonce_raw: [16]u8 = undefined;
        io.random(&nonce_raw);
        var nonce_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&nonce_b64, &nonce_raw);

        var buf: [1024]u8 = undefined;
        var sw = stream.writer(io, &buf);
        const w = &sw.interface;
        try w.print(
            "GET /apiws HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Sec-WebSocket-Protocol: binary\r\n\r\n",
            .{ host, nonce_b64 },
        );
        try w.flush();

        var resp_buf: [4096]u8 = undefined;
        var resp_len: usize = 0;
        var rbuf: [256]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const r = &sr.interface;
        while (resp_len < resp_buf.len) {
            const byte = try r.takeByte();
            resp_buf[resp_len] = byte;
            resp_len += 1;
            if (resp_len >= 4 and std.mem.eql(u8, resp_buf[resp_len - 4 .. resp_len], "\r\n\r\n")) break;
        }
        const resp = resp_buf[0..resp_len];
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) return error.WsHandshakeFailed;

        return .{ .stream = stream };
    }

    pub fn writeFrame(self: *WsTransport, io: Io, data: []const u8) !void {
        var hdr: [10]u8 = undefined;
        var hdr_len: usize = 2;
        hdr[0] = 0x82; // FIN=1, opcode=binary
        var mask_key: [4]u8 = undefined;
        io.random(&mask_key);
        const len = data.len;
        if (len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(len));
        } else if (len < 65536) {
            hdr[1] = 0xfe;
            hdr[2] = @intCast((len >> 8) & 0xff);
            hdr[3] = @intCast(len & 0xff);
            hdr_len = 4;
        } else {
            hdr[1] = 0xff;
            std.mem.writeInt(u64, hdr[2..10], @intCast(len), .big);
            hdr_len = 10;
        }
        @memcpy(hdr[hdr_len..][0..4], &mask_key);
        hdr_len += 4;

        var buf: [64]u8 = undefined;
        var sw = self.stream.writer(io, &buf);
        const w = &sw.interface;
        try w.writeAll(hdr[0..hdr_len]);
        for (data, 0..) |byte, i| try w.writeByte(byte ^ mask_key[i % 4]);
        try w.flush();
    }

    pub fn readFrame(self: *WsTransport, io: Io, allocator: Allocator) ![]u8 {
        var buf: [64]u8 = undefined;
        var sr = self.stream.reader(io, &buf);
        const r = &sr.interface;
        const b0 = try r.takeByte();
        _ = b0;
        const b1 = try r.takeByte();
        const masked = (b1 & 0x80) != 0;
        var payload_len: usize = b1 & 0x7f;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try r.readSliceAll(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try r.readSliceAll(&ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }
        var mask_key: [4]u8 = undefined;
        if (masked) try r.readSliceAll(&mask_key);
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        try r.readSliceAll(payload);
        if (masked) {
            for (payload, 0..) |*byte, i| byte.* ^= mask_key[i % 4];
        }
        return payload;
    }
};
