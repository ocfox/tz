const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const storage_mod = @import("session/storage.zig");
const codec = @import("codec");
const types = @import("types");

pub const ClientOptions = struct {
    dc: conn_mod.DC = conn_mod.default_dcs[1],
    bot_token: ?[]const u8 = null,
    api_id: i32,
    api_hash: []const u8,
    storage: storage_mod.SessionStorage,
    handler: conn_mod.UpdateHandler,
};

pub const Client = struct {
    allocator: Allocator,
    opts: ClientOptions,
    primary: ?*Conn = null,
    closed: bool = false,
    dc_resolved: bool = false,
    bot_id: ?i64 = null,

    pub fn init(allocator: Allocator, opts: ClientOptions) !*Client {
        const c = try allocator.create(Client);
        c.* = .{ .allocator = allocator, .opts = opts };
        return c;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.destroy(self);
    }

    /// Blocks until close() is called. Reconnects automatically on disconnect.
    pub fn run(self: *Client, io: Io) !void {
        var backoff_ms: u64 = 100;
        while (!self.closed) {
            self.runOnce(io) catch |err| {
                if (self.closed) return;
                std.log.warn("disconnected: {}, reconnecting in {}ms", .{ err, backoff_ms });
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
                backoff_ms = @min(backoff_ms * 5, 10_000);
                continue;
            };
            backoff_ms = 100;
        }
    }

    fn runOnce(self: *Client, io: Io) !void {
        if (!self.dc_resolved) {
            if (try self.opts.storage.load(io, self.allocator)) |saved| {
                if (findDc(saved.dc_id, self.opts.dc.test_server)) |dc| self.opts.dc = dc;
            }
            self.dc_resolved = true;
        }
        std.log.info("connecting to DC {}", .{self.opts.dc.id});
        const c = try conn_mod.connect(io, self.allocator, .{
            .dc = self.opts.dc,
            .transport = .tcp_abridged,
            .session_storage = self.opts.storage,
            .api_id = self.opts.api_id,
            .api_hash = self.opts.api_hash,
        });
        std.log.info("connected, auth key ready", .{});
        defer {
            c.close(io);
            c.join(io);
            c.deinit();
            self.primary = null;
        }
        self.primary = c;
        try c.run(io, self.opts.handler);
        if (self.opts.bot_token) |token| {
            std.log.info("authenticating bot", .{});
            self.authBot(io, token) catch |err| switch (err) {
                error.DcMigrate => {
                    std.log.info("migrating to DC {}", .{self.opts.dc.id});
                    return err;
                },
                else => return err,
            };
            std.log.info("bot authenticated", .{});
        }
        std.log.info("waiting for updates", .{});
        c.join(io);
    }

    pub fn close(self: *Client, io: Io) void {
        self.closed = true;
        if (self.primary) |c| c.close(io);
    }

    /// Send a typed TL request, return the decoded response.
    pub fn call(self: *Client, io: Io, request: anytype) !@TypeOf(request).Response {
        var fba_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        // encodeAlloc into stack buffer; slice points into fba_buf, no heap free needed
        const bytes = try codec.encodeAlloc(request, fba.allocator());
        const raw = try self.callRaw(io, bytes);
        defer self.allocator.free(raw);
        if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid) {
            try self.handleRpcError(raw);
            return error.RpcError;
        }
        var r: std.Io.Reader = .fixed(raw);
        return codec.decode(@TypeOf(request).Response, &r, self.allocator);
    }

    /// Send a typed TL request, discard the response (fire-and-check).
    fn exec(self: *Client, io: Io, request: anytype) !void {
        var fba_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const bytes = try codec.encodeAlloc(request, fba.allocator());
        const raw = try self.callRaw(io, bytes);
        defer self.allocator.free(raw);
        if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid)
            return self.handleRpcError(raw);
    }

    fn authBot(self: *Client, io: Io, token: []const u8) !void {
        const funcs = @import("functions");
        const auth = try self.call(io, funcs.auth.ImportBotAuthorization{
            .flags = 0,
            .api_id = self.opts.api_id,
            .api_hash = self.opts.api_hash,
            .bot_auth_token = token,
        });
        switch (auth) {
            .AuthAuthorization => |a| switch (a.user) {
                .User => |u| self.bot_id = u.id,
                else => {},
            },
            else => {},
        }
        try self.exec(io, funcs.updates.GetState{});
    }

    fn handleRpcError(self: *Client, raw: []const u8) !void {
        if (raw.len < 8) return error.RpcError;
        const code = std.mem.readInt(i32, raw[4..8], .little);
        const slen: usize = if (raw.len > 8 and raw[8] < 254) raw[8] else 0;
        const msg = if (9 + slen <= raw.len) raw[9 .. 9 + slen] else &[_]u8{};
        std.log.err("rpc_error: code={} msg={s}", .{ code, msg });
        if (code == 303) {
            if (parseMigrateDc(raw)) |dc_id| {
                self.opts.dc = findDc(dc_id, self.opts.dc.test_server) orelse return error.RpcError;
                return error.DcMigrate;
            }
        }
        return error.RpcError;
    }

    fn callRaw(self: *Client, io: Io, bytes: []const u8) ![]u8 {
        const c = self.primary orelse return error.NotConnected;
        if (!c.initialized) {
            c.initialized = true;
            const wrapped = try wrapInit(self.allocator, self.opts.api_id, bytes);
            defer self.allocator.free(wrapped);
            return c.call(io, wrapped);
        }
        return c.call(io, bytes);
    }
};

const layer: i32 = 225;

fn wrapInit(allocator: Allocator, api_id: i32, query_bytes: []const u8) ![]u8 {
    const ser = @import("codec").serialize;
    var hdr: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hdr);
    try w.writeInt(u32, 0xda9b0d0d, .little); // invokeWithLayer
    try w.writeInt(i32, layer, .little);
    try w.writeInt(u32, 0xc1cd5ea9, .little); // initConnection
    try w.writeInt(i32, 0, .little);           // flags
    try ser.int(&w, api_id);
    try ser.string(&w, "tz");
    try ser.string(&w, "Zig/0.16");
    try ser.string(&w, "0.1");
    try ser.string(&w, "en");
    try ser.string(&w, "");
    try ser.string(&w, "en");
    const h = w.buffered();
    const out = try allocator.alloc(u8, h.len + query_bytes.len);
    @memcpy(out[0..h.len], h);
    @memcpy(out[h.len..], query_bytes);
    return out;
}

fn parseMigrateDc(raw: []const u8) ?u8 {
    if (raw.len < 9) return null;
    const slen = raw[8];
    if (slen >= 254 or 9 + @as(usize, slen) > raw.len) return null;
    const msg = raw[9 .. 9 + slen];
    const idx = std.mem.indexOf(u8, msg, "_MIGRATE_") orelse return null;
    return std.fmt.parseInt(u8, msg[idx + "_MIGRATE_".len ..], 10) catch null;
}

fn findDc(dc_id: u8, test_server: bool) ?conn_mod.DC {
    for (conn_mod.default_dcs) |dc| {
        if (dc.id == dc_id and dc.test_server == test_server) return dc;
    }
    return null;
}
