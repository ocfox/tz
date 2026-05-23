const std = @import("std");
const Io = std.Io;
const Conn = @import("../conn.zig").Conn;
const ser = @import("codec").serialize;

pub const SignInResult = union(enum) {
    success: void,
    need_2fa: void,
};

// TODO: migrate to Client.call + generated types, same as authBot
pub const UserAuth = struct {
    pub fn sendCode(conn: *Conn, io: Io, phone: []const u8) !void {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeInt(u32, 0xa677244f, .little);
        try ser.string(&w, phone);
        try ser.int(&w, conn.api_id);
        try ser.string(&w, conn.api_hash);
        try w.writeInt(u32, 0xd45ab096, .little);
        try w.writeInt(u32, 0, .little);
        _ = try conn.call(io, w.buffered());
    }

    pub fn signIn(conn: *Conn, io: Io, phone: []const u8, phone_code_hash: []const u8, code: []const u8) !SignInResult {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeInt(u32, 0x8d52a951, .little);
        try ser.string(&w, phone);
        try ser.string(&w, phone_code_hash);
        try ser.string(&w, code);
        const resp = try conn.call(io, w.buffered());
        defer conn.allocator.free(resp);
        if (resp.len >= 4) {
            const resp_id = std.mem.readInt(u32, resp[0..4], .little);
            if (resp_id == 0x44747e9a) return .need_2fa;
        }
        return .success;
    }

    pub fn checkPassword(_: *Conn, _: Io, _: []const u8) !void {
        return error.SrpNotImplemented;
    }
};
