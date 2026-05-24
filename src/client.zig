const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const storage_mod = @import("session/storage.zig");
const codec = @import("codec");
const types = @import("types");
const functions = @import("functions");

pub const HandlerEntry = struct {
    cid: u32,
    dispatchFn: *const fn (ctx: Context, update: types.Update) anyerror!void,
};

const SubConn = struct {
    connector: *Connector,
    storage: storage_mod.MemoryStorage = .{},
};

var sub_conn_dummy: u8 = 0;
const sub_conn_noop_handler = connector_mod.UpdateHandler{
    .ptr = &sub_conn_dummy,
    .vtable = &.{ .handle = struct {
        fn h(_: *anyopaque, _: Io, _: []const u8) void {}
    }.h },
};

/// Build a HandlerEntry for a typed update.
/// cb must be: fn (ctx: Context, update: UpdateType) anyerror!void
pub fn handler(
    comptime UpdateType: type,
    comptime cb: fn (ctx: Context, update: UpdateType) anyerror!void,
) HandlerEntry {
    return .{
        .cid = UpdateType.cid,
        .dispatchFn = struct {
            fn dispatch(ctx: Context, update: types.Update) anyerror!void {
                switch (update) {
                    inline else => |inner| {
                        if (@TypeOf(inner) == UpdateType) {
                            try cb(ctx, inner);
                        }
                    },
                }
            }
        }.dispatch,
    };
}

/// Context passed to handler callbacks.
pub const Context = struct {
    client: *anyopaque,
    io: Io,
    allocator: Allocator,
    entities: Entities,
    callFn: *const fn (client: *anyopaque, io: Io, bytes: []const u8) anyerror![]u8,
    /// Like callFn but routes FILE_MIGRATE to a sub-connection automatically.
    callFileFn: *const fn (client: *anyopaque, io: Io, bytes: []const u8) anyerror![]u8,

    /// Send a typed TL request, return the decoded response.
    pub fn call(self: Context, request: anytype) !@TypeOf(request).Response {
        var fba_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const bytes = try codec.encodeAlloc(request, fba.allocator());
        const raw = try self.callFn(self.client, self.io, bytes);
        defer self.allocator.free(raw);
        var r: std.Io.Reader = .fixed(raw);
        return codec.decode(@TypeOf(request).Response, &r, self.allocator);
    }

    /// Like call but for upload RPCs: automatically follows FILE_MIGRATE to the file DC.
    /// Uses heap allocation for encoding (upload parts can be large).
    pub fn callFile(self: Context, request: anytype) !@TypeOf(request).Response {
        const bytes = try codec.encodeAlloc(request, self.allocator);
        defer self.allocator.free(bytes);
        const raw = try self.callFileFn(self.client, self.io, bytes);
        defer self.allocator.free(raw);
        var r: std.Io.Reader = .fixed(raw);
        return codec.decode(@TypeOf(request).Response, &r, self.allocator);
    }
};

pub const Entities = struct {
    users: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    channels: std.AutoHashMapUnmanaged(i64, i64) = .empty,

    fn deinit(self: *Entities, allocator: Allocator) void {
        self.users.deinit(allocator);
        self.channels.deinit(allocator);
    }

    pub fn accessHash(self: *const Entities, user_id: i64) ?i64 {
        return self.users.get(user_id);
    }

    pub fn channelAccessHash(self: *const Entities, channel_id: i64) ?i64 {
        return self.channels.get(channel_id);
    }
};

pub const ClientOptions = struct {
    dc: connector_mod.DC = connector_mod.default_dcs[1],
    bot_token: ?[]const u8 = null,
    /// Called once after the first successful connection, before the update loop.
    /// Receives an opaque pointer to the Client; cast with @ptrCast(@alignCast(ptr)).
    /// Use this for interactive user auth (sendCode / signIn). Ignored when bot_token is set.
    auth_fn: ?*const fn (*anyopaque, Io) anyerror!void = null,
    api_id: i32,
    api_hash: []const u8,
    storage: storage_mod.SessionStorage,
};

/// Client(handlers) — handlers is a comptime-known slice of HandlerEntry.
pub fn Client(comptime handlers: []const HandlerEntry) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        opts: ClientOptions,
        primary: ?*Connector = null,
        closed: bool = false,
        dc_resolved: bool = false,
        bot_id: ?i64 = null,
        user_authorized: bool = false,
        dc_list: ?[]connector_mod.DC = null,
        sub_conns: std.AutoHashMapUnmanaged(u8, *SubConn) = .empty,
        last_file_dc: ?u8 = null,

        pub fn init(allocator: Allocator, opts: ClientOptions) !*Self {
            initRandomCounter();
            const c = try allocator.create(Self);
            c.* = .{ .allocator = allocator, .opts = opts };
            return c;
        }

        pub fn deinit(self: *Self) void {
            if (self.dc_list) |list| self.allocator.free(list);
            // Sub-conns should have been closed in runOnce's defer; clean up any stragglers.
            var it = self.sub_conns.valueIterator();
            while (it.next()) |sub| {
                sub.*.connector.deinit();
                self.allocator.destroy(sub.*);
            }
            self.sub_conns.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Blocks until close() is called. Reconnects automatically on disconnect.
        pub fn run(self: *Self, io: Io) !void {
            var backoff_ms: u64 = 100;
            while (!self.closed) {
                self.runOnce(io) catch |err| {
                    if (self.closed) return;
                    if (err == error.SessionInvalid) {
                        std.log.warn("session invalid, clearing stored session", .{});
                        self.opts.storage.save(io, std.mem.zeroes(storage_mod.SessionData)) catch |e|
                            std.log.warn("failed to clear session: {}", .{e});
                        self.user_authorized = false;
                    }
                    std.log.warn("disconnected: {}, reconnecting in {}ms", .{ err, backoff_ms });
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch |e| std.log.debug("sleep: {}", .{e});
                    backoff_ms = @min(backoff_ms * 5, 10_000);
                    continue;
                };
                backoff_ms = 100;
            }
        }

        pub fn close(self: *Self, io: Io) void {
            self.closed = true;
            if (self.primary) |c| c.close(io);
        }

        /// Send a typed TL request, return the decoded response.
        pub fn call(self: *Self, io: Io, request: anytype) !@TypeOf(request).Response {
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const bytes = try codec.encodeAlloc(request, fba.allocator());
            const raw = try self.callRaw(io, bytes);
            defer self.allocator.free(raw);
            if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid) {
                try self.handleRpcError(io, raw);
                return error.RpcError;
            }
            var r: std.Io.Reader = .fixed(raw);
            return codec.decode(@TypeOf(request).Response, &r, self.allocator);
        }

        fn exec(self: *Self, io: Io, request: anytype) !void {
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const bytes = try codec.encodeAlloc(request, fba.allocator());
            const raw = try self.callRaw(io, bytes);
            defer self.allocator.free(raw);
            if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid)
                return self.handleRpcError(io, raw);
        }

        fn callImpl(ptr: *anyopaque, io2: Io, bytes: []const u8) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            for (0..4) |_| {
                const raw = try self.callRaw(io2, bytes);
                if (raw.len < 4 or std.mem.readInt(u32, raw[0..4], .little) != types.RpcError.cid)
                    return raw;
                defer self.allocator.free(raw);
                // handleRpcError returns void on FLOOD_WAIT (slept, should retry), error otherwise.
                try self.handleRpcError(io2, raw);
            }
            return error.RpcError;
        }

        fn callFileImpl(ptr: *anyopaque, io2: Io, bytes: []const u8) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            for (0..4) |_| {
                // Route directly to known file DC on subsequent parts.
                if (self.last_file_dc) |dc_id| {
                    return self.callRawOnDc(io2, dc_id, bytes);
                }
                const raw = try self.callRaw(io2, bytes);
                if (raw.len < 4 or std.mem.readInt(u32, raw[0..4], .little) != types.RpcError.cid)
                    return raw;
                const code = std.mem.readInt(i32, raw[4..8], .little);
                if (code == 303) {
                    if (parseMigrateDc(raw)) |dc_id| {
                        self.allocator.free(raw);
                        self.last_file_dc = dc_id;
                        return self.callRawOnDc(io2, dc_id, bytes);
                    }
                }
                defer self.allocator.free(raw);
                try self.handleRpcError(io2, raw);
            }
            return error.RpcError;
        }

        fn callViaConnector(self: *Self, io2: Io, c: *Connector, bytes: []const u8) ![]u8 {
            if (!c.isInitialized()) {
                c.setInitialized();
                const wrapped = try wrapInit(self.allocator, self.opts.api_id, bytes);
                defer self.allocator.free(wrapped);
                return c.call(io2, wrapped);
            }
            return c.call(io2, bytes);
        }

        fn callRawOnDc(self: *Self, io2: Io, dc_id: u8, bytes: []const u8) ![]u8 {
            const gop = try self.sub_conns.getOrPut(self.allocator, dc_id);
            if (!gop.found_existing) {
                const sub = try self.allocator.create(SubConn);
                errdefer self.allocator.destroy(sub);
                // SAFETY: connector is assigned two lines below before sub is used
                sub.* = .{ .connector = undefined };
                const dc = self.findDc(dc_id) orelse return error.DcNotFound;
                sub.connector = try Connector.connect(io2, self.allocator, .{
                    .dc = dc,
                    .transport = .tcp_abridged,
                    .session_storage = sub.storage.storage(),
                    .api_id = self.opts.api_id,
                    .api_hash = self.opts.api_hash,
                });
                errdefer sub.connector.deinit();
                try self.transferAuth(io2, sub.connector, dc_id);
                try sub.connector.run(io2, sub_conn_noop_handler);
                gop.value_ptr.* = sub;
            }
            return self.callViaConnector(io2, gop.value_ptr.*.connector, bytes);
        }

        fn transferAuth(self: *Self, io2: Io, sub: *Connector, dc_id: u8) !void {
            const exported = try self.call(io2, functions.auth.ExportAuthorization{
                .dc_id = @intCast(dc_id),
            });
            defer self.allocator.free(exported.bytes);
            var fba_buf: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const import_bytes = try codec.encodeAlloc(functions.auth.ImportAuthorization{
                .id = exported.id,
                .bytes = exported.bytes,
            }, fba.allocator());
            const raw = try self.callViaConnector(io2, sub, import_bytes);
            defer self.allocator.free(raw);
            if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid)
                return error.AuthTransferFailed;
        }

        fn runOnce(self: *Self, io: Io) !void {
            if (!self.dc_resolved) {
                if (try self.opts.storage.load(io, self.allocator)) |saved| {
                    if (connector_mod.findDc(saved.dc_id, self.opts.dc.test_server)) |dc| self.opts.dc = dc;
                }
                self.dc_resolved = true;
            }
            std.log.info("connecting to DC {}", .{self.opts.dc.id});
            const c = try Connector.connect(io, self.allocator, .{
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
                c.saveSession(io);
                c.deinit();
                self.primary = null;
                var sub_it = self.sub_conns.valueIterator();
                while (sub_it.next()) |sub| {
                    sub.*.connector.close(io);
                    sub.*.connector.join(io);
                    sub.*.connector.deinit();
                    self.allocator.destroy(sub.*);
                }
                self.sub_conns.clearRetainingCapacity();
                self.last_file_dc = null;
            }
            self.primary = c;

            const update_handler: connector_mod.UpdateHandler = .{
                .ptr = self,
                .vtable = &.{ .handle = handleUpdate },
            };
            try c.run(io, update_handler);

            if (self.opts.bot_token) |token| {
                if (self.bot_id == null) {
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
            } else if (self.opts.auth_fn) |f| {
                if (!self.user_authorized) {
                    try f(self, io);
                    self.user_authorized = true;
                }
            }
            self.fetchDcList(io) catch |err|
                std.log.warn("failed to fetch DC list: {}", .{err});
            std.log.info("waiting for updates", .{});
            c.join(io);
        }

        fn fetchDcList(self: *Self, io: Io) !void {
            const config = try self.call(io, functions.help.GetConfig{});
            defer self.allocator.free(config.dc_options);
            var list: std.ArrayList(connector_mod.DC) = .empty;
            defer list.deinit(self.allocator);
            for (config.dc_options) |opt| {
                if (opt.cdn.value != null) continue;
                if (opt.media_only.value != null) continue;
                if (opt.ipv6.value != null) continue;
                const id = std.math.cast(u8, opt.id) orelse continue;
                const addr = std.Io.net.IpAddress.parseIp4(opt.ip_address, @intCast(opt.port)) catch continue;
                try list.append(self.allocator, .{ .id = id, .addr = addr, .test_server = self.opts.dc.test_server });
            }
            if (self.dc_list) |old| self.allocator.free(old);
            self.dc_list = try list.toOwnedSlice(self.allocator);
            std.log.info("DC list updated: {} entries", .{self.dc_list.?.len});
        }

        fn authBot(self: *Self, io: Io, token: []const u8) !void {
            const auth = try self.call(io, functions.auth.ImportBotAuthorization{
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
            try self.exec(io, functions.updates.GetState{});
        }

        fn findDc(self: *const Self, dc_id: u8) ?connector_mod.DC {
            if (self.dc_list) |list| {
                for (list) |dc| {
                    if (dc.id == dc_id) return dc;
                }
            }
            return connector_mod.findDc(dc_id, self.opts.dc.test_server);
        }

        fn callRaw(self: *Self, io: Io, bytes: []const u8) ![]u8 {
            return self.callViaConnector(io, self.primary orelse return error.NotConnected, bytes);
        }

        fn handleRpcError(self: *Self, io: Io, raw: []const u8) !void {
            if (raw.len < 8) return error.RpcError;
            const code = std.mem.readInt(i32, raw[4..8], .little);
            const slen: usize = if (raw.len > 8 and raw[8] < 254) raw[8] else 0;
            const msg = if (9 + slen <= raw.len) raw[9 .. 9 + slen] else &[_]u8{};
            std.log.err("rpc_error: code={} msg={s}", .{ code, msg });
            if (code == 420) {
                if (std.mem.indexOf(u8, msg, "FLOOD_WAIT_")) |idx| {
                    const secs = std.fmt.parseInt(u64, msg[idx + "FLOOD_WAIT_".len ..], 10) catch 60;
                    std.log.warn("flood wait: sleeping {}s", .{secs});
                    std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(secs)), .awake) catch |err| std.log.debug("sleep: {}", .{err});
                    return; // caller should retry
                }
            }
            if (code == 303) {
                if (parseMigrateDc(raw)) |dc_id| {
                    self.opts.dc = self.findDc(dc_id) orelse return error.RpcError;
                    return error.DcMigrate;
                }
            }
            if (code == 401) return error.SessionInvalid;
            if (std.mem.eql(u8, msg, "SESSION_PASSWORD_NEEDED")) return error.SessionPasswordNeeded;
            return error.RpcError;
        }

        fn handleUpdate(ptr: *anyopaque, io: Io, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (payload.len < 4) return;
            const cid = std.mem.readInt(u32, payload[0..4], .little);
            if (cid != 0x74ae4240) return; // only Updates_ container
            self.dispatchUpdates(io, payload) catch |err|
                std.log.warn("update dispatch error: {}", .{err});
        }

        fn dispatchUpdates(self: *Self, io: Io, payload: []const u8) !void {
            if (handlers.len == 0) return;
            var r: std.Io.Reader = .fixed(payload[4..]);
            const upd = try codec.decodeStructBody(types.Updates_, &r, self.allocator);
            defer {
                self.allocator.free(upd.updates);
                self.allocator.free(upd.users);
                self.allocator.free(upd.chats);
            }

            var entities: Entities = .{};
            defer entities.deinit(self.allocator);
            for (upd.users) |u| switch (u) {
                .User => |user| if (user.access_hash.value) |ah|
                    try entities.users.put(self.allocator, user.id, ah),
                else => {},
            };
            for (upd.chats) |c| switch (c) {
                .Channel => |ch| if (ch.access_hash.value) |ah|
                    try entities.channels.put(self.allocator, ch.id, ah),
                else => {},
            };

            const ctx = Context{
                .client = self,
                .io = io,
                .allocator = self.allocator,
                .entities = entities,
                .callFn = callImpl,
                .callFileFn = callFileImpl,
            };

            for (upd.updates) |u| {
                const update_cid: u32 = switch (u) {
                    inline else => |body| @TypeOf(body).cid,
                };
                inline for (handlers) |entry| {
                    if (update_cid == entry.cid) {
                        entry.dispatchFn(ctx, u) catch |err|
                            std.log.warn("handler error: {}", .{err});
                    }
                }
            }
        }
    };
}

var random_counter = std.atomic.Value(i64).init(0);

pub fn nextRandomId() i64 {
    return random_counter.fetchAdd(1, .monotonic);
}

fn initRandomCounter() void {
    var seed: [32]u8 = undefined;
    _ = std.os.linux.getrandom(&seed, seed.len, 0);
    var csprng = std.Random.DefaultCsprng.init(seed);
    random_counter.store(csprng.random().int(i64), .monotonic);
}

const layer: i32 = 225;

fn wrapInit(allocator: Allocator, api_id: i32, query_bytes: []const u8) ![]u8 {
    const ser = @import("codec").serialize;
    var hdr: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hdr);
    try w.writeInt(u32, 0xda9b0d0d, .little); // invokeWithLayer
    try w.writeInt(i32, layer, .little);
    try w.writeInt(u32, 0xc1cd5ea9, .little); // initConnection
    try w.writeInt(i32, 0, .little);
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
