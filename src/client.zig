const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Connector = @import("Connector.zig");
const Storage = @import("Storage.zig");
const codec = @import("codec");
const types = @import("types");
const functions = @import("functions");
const ulog = std.log.scoped(.updates);

pub const HandlerEntry = struct {
    cid: u32,
    dispatch: *const fn (ctx: Context, update: types.Update) anyerror!void,
};

/// Owned decode result: `value` and all of its nested allocations live in `arena`.
/// Free the whole tree at once with `deinit()` — there is no per-field freeing and
/// no way to under/over-free. Mirrors the ownership model of `std.json.Parsed(T)`.
pub fn Response(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// Decode `raw` into a freshly-allocated arena and hand back an owning `Response(T)`.
fn decodeOwned(comptime T: type, raw: []const u8, gpa: Allocator) !Response(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var r: std.Io.Reader = .fixed(raw);
    const value = try codec.decode(T, &r, arena.allocator());
    return .{ .arena = arena, .value = value };
}

var subConnDummy: u8 = 0;
const sub_conn_noop_handler = Connector.UpdateHandler{
    .ptr = &subConnDummy,
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
        .dispatch = struct {
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
    api_id: i32,
    api_hash: []const u8,
    entities: Entities,
    peer_cache: *const @import("updates/PeerCache.zig"),
    mb_mutex: *std.Io.Mutex,
    callFn: *const fn (client: *anyopaque, io: Io, bytes: []const u8) anyerror![]u8,
    /// Like callFn but routes FILE_MIGRATE to a sub-connection automatically.
    callFileFn: *const fn (client: *anyopaque, io: Io, bytes: []const u8) anyerror![]u8,

    /// Send a typed TL request, return the decoded response. The caller owns the
    /// result and must free it with `resp.deinit()`. If you don't need the
    /// response, use `exec` instead — it allocates nothing for the reply.
    pub fn call(self: Context, request: anytype) !Response(@TypeOf(request).Response) {
        const bytes = try codec.encodeAlloc(request, self.allocator);
        defer self.allocator.free(bytes);
        const raw = try self.callFn(self.client, self.io, bytes);
        defer self.allocator.free(raw);
        return decodeOwned(@TypeOf(request).Response, raw, self.allocator);
    }

    /// Send a typed TL request, discard the response.
    pub fn exec(self: Context, request: anytype) !void {
        const bytes = try codec.encodeAlloc(request, self.allocator);
        defer self.allocator.free(bytes);
        const raw = try self.callFn(self.client, self.io, bytes);
        self.allocator.free(raw);
    }

    /// Like call but for upload/download RPCs: automatically follows FILE_MIGRATE to
    /// the file DC. Uses heap allocation for encoding (upload parts can be large).
    /// The caller owns the result and must free it with `resp.deinit()`.
    pub fn callFile(self: Context, request: anytype) !Response(@TypeOf(request).Response) {
        const bytes = try codec.encodeAlloc(request, self.allocator);
        defer self.allocator.free(bytes);
        const raw = try self.callFileFn(self.client, self.io, bytes);
        defer self.allocator.free(raw);
        return decodeOwned(@TypeOf(request).Response, raw, self.allocator);
    }

    /// Like callFile but discards the response (e.g. SaveFilePart returns only Bool).
    pub fn execFile(self: Context, request: anytype) !void {
        const bytes = try codec.encodeAlloc(request, self.allocator);
        defer self.allocator.free(bytes);
        const raw = try self.callFileFn(self.client, self.io, bytes);
        self.allocator.free(raw);
    }

    /// Resolve a known peer's InputPeer (observed during this session).
    pub fn resolvePeer(self: Context, id: i64) ?types.InputPeer {
        self.mb_mutex.lockUncancelable(self.io);
        defer self.mb_mutex.unlock(self.io);
        return self.peer_cache.inputPeer(id);
    }
    pub fn resolveInputChannel(self: Context, id: i64) ?types.InputChannel {
        self.mb_mutex.lockUncancelable(self.io);
        defer self.mb_mutex.unlock(self.io);
        return self.peer_cache.inputChannel(id);
    }
};

pub const Entities = struct {
    users: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    channels: std.AutoHashMapUnmanaged(i64, i64) = .empty,

    pub fn accessHash(self: *const Entities, user_id: i64) ?i64 {
        return self.users.get(user_id);
    }

    pub fn channelAccessHash(self: *const Entities, channel_id: i64) ?i64 {
        return self.channels.get(channel_id);
    }
};

pub const ClientOptions = struct {
    dc: Connector.DC = Connector.default_dcs[1],
    bot_token: ?[]const u8 = null,
    /// Called once after the first successful connection, before the update loop.
    /// Receives an opaque pointer to the Client; cast with @ptrCast(@alignCast(ptr)).
    /// Use this for interactive user auth (sendCode / signIn). Ignored when bot_token is set.
    /// Receives a `Context` — call TL functions through `ctx.call` / `ctx.exec`, same as
    /// in update handlers; `ctx.api_id` / `ctx.api_hash` are available for the initial sendCode.
    auth_fn: ?*const fn (Context) anyerror!void = null,
    api_id: i32,
    api_hash: []const u8,
    storage: Storage,
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
        dc_list: ?[]Connector.DC = null,
        sub_conns: std.AutoHashMapUnmanaged(u8, *Connector) = .empty,
        sub_conns_mu: std.Io.Mutex = std.Io.Mutex.init,
        message_box: @import("updates/MessageBox.zig") = .{},
        peer_cache: @import("updates/PeerCache.zig") = .{},
        mb_mutex: std.Io.Mutex = .init,
        state_initialized: bool = false,
        sync_event: std.Io.Event = .unset,
        sync_stop: bool = false,

        pub fn init(allocator: Allocator, opts: ClientOptions) !*Self {
            const c = try allocator.create(Self);
            c.* = .{ .allocator = allocator, .opts = opts };
            return c;
        }

        pub fn deinit(self: *Self) void {
            if (self.dc_list) |list| self.allocator.free(list);
            // Sub-conns should have been closed in runOnce's defer; clean up any stragglers.
            var it = self.sub_conns.valueIterator();
            while (it.next()) |conn| conn.*.deinit();
            self.message_box.deinit(self.allocator);
            self.peer_cache.deinit(self.allocator);
            self.sub_conns.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Blocks until close() is called. Reconnects automatically on disconnect.
        pub fn run(self: *Self, io: Io) !void {
            try initRandomCounter(io);
            var backoff_ms: u64 = 100;
            while (!self.closed) {
                self.runOnce(io) catch |err| {
                    if (self.closed) return;
                    if (err == error.SessionInvalid) {
                        std.log.warn("session invalid, clearing stored session", .{});
                        const dc_id = if (self.primary) |p| p.dc_id else 0;
                        var blank = std.mem.zeroes(Storage.SessionData);
                        blank.dc_id = dc_id;
                        self.opts.storage.save(io, self.allocator, blank) catch |e|
                            std.log.warn("failed to clear session: {}", .{e});
                        self.user_authorized = false;
                    }
                    // Jitter: ±20% of current backoff to avoid thundering herd.
                    var jitter_byte: [1]u8 = undefined;
                    io.random(&jitter_byte);
                    const jitter = backoff_ms * (80 + @as(u64, jitter_byte[0] % 41)) / 100;
                    std.log.warn("disconnected: {}, reconnecting in {}ms", .{ err, jitter });
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(jitter)), .awake) catch |e| std.log.debug("sleep: {}", .{e});
                    backoff_ms = @min(backoff_ms * 2, 30_000);
                    continue;
                };
                backoff_ms = 100;
            }
        }

        pub fn close(self: *Self, io: Io) void {
            self.closed = true;
            if (self.primary) |c| c.close(io);
        }

        /// Send a typed TL request, return the decoded response. The caller owns the
        /// result and must free it with `resp.deinit()`; use `exec` to discard it.
        pub fn call(self: *Self, io: Io, request: anytype) !Response(@TypeOf(request).Response) {
            const bytes = try codec.encodeAlloc(request, self.allocator);
            defer self.allocator.free(bytes);
            const raw = try self.callRaw(io, bytes);
            defer self.allocator.free(raw);
            if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid) {
                try self.handleRpcError(io, raw);
                return error.RpcError;
            }
            return decodeOwned(@TypeOf(request).Response, raw, self.allocator);
        }

        /// Send a typed TL request, discard the response.
        pub fn exec(self: *Self, io: Io, request: anytype) !void {
            const bytes = try codec.encodeAlloc(request, self.allocator);
            defer self.allocator.free(bytes);
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
                const raw = try self.callRaw(io2, bytes);
                if (raw.len < 4 or std.mem.readInt(u32, raw[0..4], .little) != types.RpcError.cid)
                    return raw;
                const code = std.mem.readInt(i32, raw[4..8], .little);
                if (code == 303) {
                    if (parseMigrateDc(raw)) |dc_id| {
                        std.log.debug("file: FILE_MIGRATE to DC {}", .{dc_id});
                        self.allocator.free(raw);
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

        fn getOrCreateSubConn(self: *Self, io2: Io, dc_id: u8) !*Connector {
            // Fast path: already exists.
            {
                try self.sub_conns_mu.lock(io2);
                defer self.sub_conns_mu.unlock(io2);
                if (self.sub_conns.get(dc_id)) |conn| return conn;
            }

            // Slow path: create outside the lock so blocking ops don't stall other coroutines.
            const dc = self.findDc(dc_id) orelse return error.DcNotFound;
            const conn = try Connector.connect(io2, self.allocator, .{
                .dc = dc,
                .transport = .abridged,
                .storage = self.opts.storage,
                .api_id = self.opts.api_id,
                .api_hash = self.opts.api_hash,
            });
            errdefer conn.deinit();
            // run() before transferAuth: loops must be running so mtp.call can complete.
            try conn.run(io2, sub_conn_noop_handler);
            errdefer {
                conn.close(io2);
                conn.join(io2);
            }
            try self.transferAuth(io2, conn, dc_id);

            // Insert under lock. Handle the race where another coroutine beat us here.
            try self.sub_conns_mu.lock(io2);
            const gop = self.sub_conns.getOrPut(self.allocator, dc_id) catch |err| {
                self.sub_conns_mu.unlock(io2);
                return err;
            };
            if (gop.found_existing) {
                // Another coroutine won the race; discard ours.
                const existing = gop.value_ptr.*;
                self.sub_conns_mu.unlock(io2);
                conn.close(io2);
                conn.join(io2);
                conn.deinit();
                return existing;
            }
            gop.value_ptr.* = conn;
            self.sub_conns_mu.unlock(io2);
            return conn;
        }

        fn removeSubConn(self: *Self, io2: Io, dc_id: u8) void {
            self.sub_conns_mu.lock(io2) catch return;
            const kv = self.sub_conns.fetchRemove(dc_id) orelse {
                self.sub_conns_mu.unlock(io2);
                return;
            };
            self.sub_conns_mu.unlock(io2);
            // Join before deinit to avoid use-after-free in the running loops.
            kv.value.close(io2);
            kv.value.join(io2);
            kv.value.deinit();
        }

        fn callRawOnDc(self: *Self, io2: Io, dc_id: u8, bytes: []const u8) ![]u8 {
            const conn = try self.getOrCreateSubConn(io2, dc_id);
            return self.callViaConnector(io2, conn, bytes) catch |err| {
                self.removeSubConn(io2, dc_id);
                return err;
            };
        }

        fn transferAuth(self: *Self, io2: Io, sub: *Connector, dc_id: u8) !void {
            const exported_resp = try self.call(io2, functions.auth.ExportAuthorization{
                .dc_id = @intCast(dc_id),
            });
            defer exported_resp.deinit();
            const exported = exported_resp.value;
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try codec.encode(functions.auth.ImportAuthorization{
                .id = exported.id,
                .bytes = exported.bytes,
            }, &w);
            const raw = try self.callViaConnector(io2, sub, w.buffered());
            defer self.allocator.free(raw);
            if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == types.RpcError.cid)
                return error.AuthTransferFailed;
        }

        fn markHomeDc(self: *Self, io: Io) void {
            if (self.primary) |c| {
                c.is_home = true;
                c.saveSession(io);
            }
        }

        fn runOnce(self: *Self, io: Io) !void {
            if (!self.dc_resolved) {
                scan: for (1..Storage.max_dc_id + 1) |id| {
                    const slot = try self.opts.storage.load(io, self.allocator, @intCast(id)) orelse continue;
                    if (slot.is_home) {
                        if (Connector.findDc(slot.dc_id, self.opts.dc.test_server)) |dc| self.opts.dc = dc;
                        break :scan;
                    }
                }
                self.dc_resolved = true;
            }
            std.log.info("connecting to DC {}", .{self.opts.dc.id});
            const c = try Connector.connect(io, self.allocator, .{
                .dc = self.opts.dc,
                .transport = .abridged,
                .storage = self.opts.storage,
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
                    sub.*.close(io);
                    sub.*.join(io);
                    sub.*.deinit();
                }
                self.sub_conns.clearRetainingCapacity();
            }
            self.primary = c;

            const update_handler: Connector.UpdateHandler = .{
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
                    self.markHomeDc(io);
                }
            } else if (self.opts.auth_fn) |f| {
                if (!self.user_authorized) {
                    try f(Context{
                        .client = self,
                        .io = io,
                        .allocator = self.allocator,
                        .api_id = self.opts.api_id,
                        .api_hash = self.opts.api_hash,
                        .entities = .{},
                        .peer_cache = &self.peer_cache,
                        .mb_mutex = &self.mb_mutex,
                        .callFn = callImpl,
                        .callFileFn = callFileImpl,
                    });
                    self.user_authorized = true;
                    self.markHomeDc(io);
                }
            }
            self.initUpdateState(io) catch |err|
                std.log.warn("failed to init update state: {}", .{err});
            self.fetchDcList(io) catch |err|
                std.log.warn("failed to fetch DC list: {}", .{err});

            self.sync_stop = false;
            self.sync_event.reset();
            var sync_future = std.Io.async(io, syncLoop, .{ self, io });
            {
                self.mb_mutex.lockUncancelable(io);
                const pending = self.message_box.getting_diff or self.message_box.getting_channel_diff.count() > 0;
                self.mb_mutex.unlock(io);
                if (pending) self.sync_event.set(io);
            }
            defer {
                self.sync_stop = true;
                self.sync_event.set(io);
                _ = sync_future.await(io);
            }

            std.log.info("waiting for updates", .{});
            c.join(io);
        }

        fn fetchDcList(self: *Self, io: Io) !void {
            const config_resp = try self.call(io, functions.help.GetConfig{});
            defer config_resp.deinit();
            const config = config_resp.value;
            var list: std.ArrayList(Connector.DC) = .empty;
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

        fn initUpdateState(self: *Self, io: Io) !void {
            if (self.state_initialized) return;
            if (try self.opts.storage.loadUpdateState(io, self.allocator)) |blob| {
                defer self.allocator.free(blob);
                var r: std.Io.Reader = .fixed(blob);
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                self.message_box.deserialize(self.allocator, &r) catch |e| {
                    std.log.warn("update state deserialize failed ({}), resetting", .{e});
                    self.message_box.deinit(self.allocator);
                    self.message_box = .{};
                };
                ulog.info("loaded state pts={} qts={} date={} seq={} channels={}", .{
                    self.message_box.pts,              self.message_box.qts,
                    self.message_box.date,             self.message_box.seq,
                    self.message_box.channels.count(),
                });
                if (self.message_box.pts != 0) self.message_box.getting_diff = true;
                var it = self.message_box.channels.keyIterator();
                while (it.next()) |k| {
                    try self.message_box.getting_channel_diff.put(self.allocator, k.*, {});
                }
            } else {
                ulog.info("no persisted state", .{});
            }
            const need_state = blk: {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                break :blk self.message_box.pts == 0;
            };
            if (need_state) {
                const st_resp = try self.call(io, functions.updates.GetState{});
                defer st_resp.deinit();
                const st = st_resp.value;
                self.mb_mutex.lockUncancelable(io);
                self.message_box.setState(st);
                self.mb_mutex.unlock(io);
                ulog.info("GetState -> pts={} qts={} date={} seq={}", .{ st.pts, st.qts, st.date, st.seq });
            }
            self.state_initialized = true;
        }

        fn syncLoop(self: *Self, io: Io) void {
            while (true) {
                self.sync_event.waitTimeout(io, .{ .duration = .{
                    .raw = std.Io.Duration.fromSeconds(60),
                    .clock = .awake,
                } }) catch |err| ulog.debug("syncLoop waitTimeout: {}", .{err});
                self.sync_event.reset();
                if (self.closed or self.sync_stop) return;
                ulog.debug("syncLoop wake: getting_diff={} channel_gaps={}", .{
                    self.message_box.getting_diff, self.message_box.getting_channel_diff.count(),
                });
                self.drainDifferences(io) catch |err|
                    ulog.warn("drainDifferences: {}", .{err});
            }
        }

        fn drainDifferences(self: *Self, io: Io) !void {
            var changed = false;
            var guard: usize = 0;
            while (guard < 100) : (guard += 1) {
                if (self.sync_stop) break;
                const req = blk: {
                    self.mb_mutex.lockUncancelable(io);
                    defer self.mb_mutex.unlock(io);
                    break :blk self.message_box.takeDifferenceRequest();
                } orelse break;
                changed = true;
                switch (req) {
                    .common => |gd| try self.fetchCommonDiff(io, gd),
                    .channel => |ch| try self.fetchChannelDiff(io, ch.id, ch.req),
                }
            }
            if (changed) self.persistState(io);
        }

        fn fetchCommonDiff(self: *Self, io: Io, gd: functions.updates.GetDifference) !void {
            ulog.info("GetDifference pts={} qts={} date={}", .{ gd.pts, gd.qts, gd.date });
            const diff_resp = try self.call(io, gd);
            defer diff_resp.deinit();
            const diff = diff_resp.value;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const applied = blk: {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                const a = try self.message_box.applyDifference(arena.allocator(), diff);
                try self.peer_cache.update(self.allocator, a.users, a.chats);
                self.recordChannelHashesLocked(a.chats);
                break :blk a;
            };
            ulog.info("applyDifference -> pts={} ups={} has_more={}", .{
                self.message_box.pts, applied.updates.len, applied.has_more,
            });
            try self.dispatchUpdateSlice(io, arena.allocator(), applied.updates, applied.users, applied.chats);
        }

        fn fetchChannelDiff(self: *Self, io: Io, id: i64, base: functions.updates.GetChannelDifference) !void {
            var req = base;
            {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                if (self.peer_cache.inputChannel(id)) |ic| {
                    req.channel = ic;
                } else {
                    _ = self.message_box.getting_channel_diff.remove(id);
                    ulog.warn("channel {} access_hash unknown, skipping diff", .{id});
                    return;
                }
            }
            ulog.info("GetChannelDifference channel={} pts={}", .{ id, req.pts });
            const diff_resp = self.call(io, req) catch |err| switch (err) {
                error.ChannelInvalid => {
                    self.mb_mutex.lockUncancelable(io);
                    defer self.mb_mutex.unlock(io);
                    self.message_box.dropChannel(id);
                    ulog.warn("channel {} invalid, dropping from diff tracking", .{id});
                    return;
                },
                else => return err,
            };
            defer diff_resp.deinit();
            const diff = diff_resp.value;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const applied = blk: {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                const a = try self.message_box.applyChannelDifference(self.allocator, arena.allocator(), id, diff);
                try self.peer_cache.update(self.allocator, a.users, a.chats);
                self.recordChannelHashesLocked(a.chats);
                break :blk a;
            };
            ulog.info("applyChannelDifference ch={} ups={} has_more={}", .{
                id, applied.updates.len, applied.has_more,
            });
            try self.dispatchUpdateSlice(io, arena.allocator(), applied.updates, applied.users, applied.chats);
        }

        fn persistState(self: *Self, io: Io) void {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                self.message_box.serialize(&aw.writer) catch |e| {
                    std.log.debug("serialize state: {}", .{e});
                    return;
                };
            }
            self.opts.storage.saveUpdateState(io, self.allocator, aw.written()) catch |e|
                std.log.debug("saveUpdateState: {}", .{e});
        }

        fn authBot(self: *Self, io: Io, token: []const u8) !void {
            const auth_resp = try self.call(io, functions.auth.ImportBotAuthorization{
                .flags = 0,
                .api_id = self.opts.api_id,
                .api_hash = self.opts.api_hash,
                .bot_auth_token = token,
            });
            defer auth_resp.deinit();
            const auth = auth_resp.value;
            switch (auth) {
                .AuthAuthorization => |a| switch (a.user) {
                    .User => |u| self.bot_id = u.id,
                    else => {},
                },
                else => {},
            }
        }

        fn findDc(self: *const Self, dc_id: u8) ?Connector.DC {
            if (self.dc_list) |list| {
                for (list) |dc| {
                    if (dc.id == dc_id) return dc;
                }
            }
            return Connector.findDc(dc_id, self.opts.dc.test_server);
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
            // SESSION_PASSWORD_NEEDED is a 401 but means "needs 2FA", not a dead
            // session — match it before the blanket 401 check below.
            if (std.mem.eql(u8, msg, "SESSION_PASSWORD_NEEDED")) return error.SessionPasswordNeeded;
            if (code == 401) return error.SessionInvalid;
            // Retryable user-input errors: surface them distinctly so callers can
            // re-prompt in place instead of tearing down the connection.
            if (std.mem.eql(u8, msg, "PHONE_CODE_INVALID")) return error.PhoneCodeInvalid;
            if (std.mem.eql(u8, msg, "PASSWORD_HASH_INVALID")) return error.PasswordHashInvalid;
            // Channel we can't access: permanent, so the diff loop must drop it
            // rather than retry forever.
            if (std.mem.eql(u8, msg, "CHANNEL_INVALID")) return error.ChannelInvalid;
            return error.RpcError;
        }

        fn handleUpdate(ptr: *anyopaque, io: Io, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (payload.len < 4) return;
            const cid = std.mem.readInt(u32, payload[0..4], .little);
            switch (cid) {
                types.Updates_.cid, types.UpdatesCombined.cid => self.dispatchUpdates(io, payload) catch |err|
                    std.log.warn("update dispatch error: {}", .{err}),
                types.UpdateShort.cid => self.dispatchShort(io, payload) catch |err|
                    std.log.warn("update dispatch error: {}", .{err}),
                types.UpdateShortMessage.cid => self.dispatchShortMessage(io, payload) catch |err|
                    std.log.warn("update dispatch error: {}", .{err}),
                types.UpdateShortChatMessage.cid => self.dispatchShortChatMessage(io, payload) catch |err|
                    std.log.warn("update dispatch error: {}", .{err}),
                types.UpdatesTooLong.cid => {
                    self.mb_mutex.lockUncancelable(io);
                    self.message_box.getting_diff = true;
                    self.mb_mutex.unlock(io);
                    self.sync_event.set(io);
                },
                else => {},
            }
        }

        fn dispatchUpdateSlice(
            self: *Self,
            io: Io,
            arena_alloc: Allocator,
            updates: []const types.Update,
            users: []const types.User,
            chats: []const types.Chat,
        ) !void {
            var entities: Entities = .{};
            for (users) |u| switch (u) {
                .User => |user| if (user.access_hash.value) |ah|
                    try entities.users.put(arena_alloc, user.id, ah),
                else => {},
            };
            for (chats) |c| switch (c) {
                .Channel => |ch| if (ch.access_hash.value) |ah|
                    try entities.channels.put(arena_alloc, ch.id, ah),
                else => {},
            };

            const ctx = Context{
                .client = self,
                .io = io,
                .allocator = self.allocator,
                .api_id = self.opts.api_id,
                .api_hash = self.opts.api_hash,
                .entities = entities,
                .peer_cache = &self.peer_cache,
                .mb_mutex = &self.mb_mutex,
                .callFn = callImpl,
                .callFileFn = callFileImpl,
            };

            for (updates) |u| {
                const update_cid: u32 = switch (u) {
                    inline else => |body| @TypeOf(body).cid,
                };
                inline for (handlers) |entry| {
                    if (update_cid == entry.cid) {
                        entry.dispatch(ctx, u) catch |err|
                            std.log.warn("handler error: {}", .{err});
                    }
                }
            }
        }

        /// Runs updates through the MessageBox, applies peer info, then dispatches
        /// the confirmed-order updates. On gap, signals sync_event (never blocks).
        fn routeUpdates(
            self: *Self,
            io: Io,
            arena_alloc: Allocator,
            updates: []const types.Update,
            users: []const types.User,
            chats: []const types.Chat,
        ) !void {
            var applied: []types.Update = &.{};
            var gap = false;
            {
                self.mb_mutex.lockUncancelable(io);
                defer self.mb_mutex.unlock(io);
                self.peer_cache.update(self.allocator, users, chats) catch |e|
                    std.log.debug("peer_cache: {}", .{e});
                self.recordChannelHashesLocked(chats);
                const res = self.message_box.processUpdates(self.allocator, arena_alloc, updates) catch |e| {
                    std.log.debug("processUpdates: {}", .{e});
                    return;
                };
                applied = res.applied;
                gap = self.message_box.getting_diff or self.message_box.getting_channel_diff.count() > 0;
            }
            ulog.debug("routeUpdates: in={} applied={} gap={} pts={} qts={}", .{
                updates.len, applied.len, gap, self.message_box.pts, self.message_box.qts,
            });
            try self.dispatchUpdateSlice(io, arena_alloc, applied, users, chats);
            if (gap) self.sync_event.set(io);
        }

        /// Caller must hold mb_mutex.
        fn recordChannelHashesLocked(self: *Self, chats: []const types.Chat) void {
            for (chats) |c| switch (c) {
                .Channel => |ch| if (ch.access_hash.value) |ah| {
                    const gop = self.message_box.channels.getOrPut(self.allocator, ch.id) catch return;
                    if (gop.found_existing) {
                        gop.value_ptr.access_hash = ah;
                    } else {
                        gop.value_ptr.* = .{ .pts = 0, .access_hash = ah };
                    }
                },
                else => {},
            };
        }

        fn dispatchUpdates(self: *Self, io: Io, payload: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var r: std.Io.Reader = .fixed(payload[4..]);
            const cid = std.mem.readInt(u32, payload[0..4], .little);
            if (cid == types.UpdatesCombined.cid) {
                const upd = try codec.decodeStructBody(types.UpdatesCombined, &r, arena_alloc);
                try self.routeUpdates(io, arena_alloc, upd.updates, upd.users, upd.chats);
            } else {
                const upd = try codec.decodeStructBody(types.Updates_, &r, arena_alloc);
                try self.routeUpdates(io, arena_alloc, upd.updates, upd.users, upd.chats);
            }
        }

        fn dispatchShort(self: *Self, io: Io, payload: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var r: std.Io.Reader = .fixed(payload[4..]);
            const upd = try codec.decodeStructBody(types.UpdateShort, &r, arena_alloc);
            const updates = [_]types.Update{upd.update};
            try self.routeUpdates(io, arena_alloc, &updates, &.{}, &.{});
        }

        fn dispatchShortMessage(self: *Self, io: Io, payload: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var r: std.Io.Reader = .fixed(payload[4..]);
            const short = try codec.decodeStructBody(types.UpdateShortMessage, &r, arena_alloc);
            const msg = types.Message_{
                .id = short.id,
                .out = short.out,
                .mentioned = short.mentioned,
                .media_unread = short.media_unread,
                .silent = short.silent,
                .from_id = if (short.out.value != null) .none else .{ .value = .{ .PeerUser = .{ .user_id = short.user_id } } },
                .peer_id = .{ .PeerUser = .{ .user_id = short.user_id } },
                .date = short.date,
                .message = short.message,
                .fwd_from = short.fwd_from,
                .via_bot_id = short.via_bot_id,
                .reply_to = short.reply_to,
                .entities = short.entities,
                .ttl_period = short.ttl_period,
            };
            const updates = [_]types.Update{.{ .UpdateNewMessage = .{
                .message = .{ .Message = msg },
                .pts = short.pts,
                .pts_count = short.pts_count,
            } }};
            try self.routeUpdates(io, arena_alloc, &updates, &.{}, &.{});
        }

        fn dispatchShortChatMessage(self: *Self, io: Io, payload: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var r: std.Io.Reader = .fixed(payload[4..]);
            const short = try codec.decodeStructBody(types.UpdateShortChatMessage, &r, arena_alloc);
            const msg = types.Message_{
                .id = short.id,
                .out = short.out,
                .mentioned = short.mentioned,
                .media_unread = short.media_unread,
                .silent = short.silent,
                .from_id = .{ .value = .{ .PeerUser = .{ .user_id = short.from_id } } },
                .peer_id = .{ .PeerChat = .{ .chat_id = short.chat_id } },
                .date = short.date,
                .message = short.message,
                .fwd_from = short.fwd_from,
                .via_bot_id = short.via_bot_id,
                .reply_to = short.reply_to,
                .entities = short.entities,
                .ttl_period = short.ttl_period,
            };
            const updates = [_]types.Update{.{ .UpdateNewMessage = .{
                .message = .{ .Message = msg },
                .pts = short.pts,
                .pts_count = short.pts_count,
            } }};
            try self.routeUpdates(io, arena_alloc, &updates, &.{}, &.{});
        }
    };
}

pub const nextRandomId = codec.nextRandomId;

fn initRandomCounter(io: Io) !void {
    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed);
    var csprng = std.Random.DefaultCsprng.init(seed);
    codec.initRandom(csprng.random().int(i64));
}

const layer: i32 = 225;

fn wrapInit(allocator: Allocator, api_id: i32, query_bytes: []const u8) ![]u8 {
    const ser = @import("codec").serialize;
    var hdr: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hdr);
    try w.writeInt(u32, functions.InvokeWithLayer.cid, .little);
    try w.writeInt(i32, layer, .little);
    try w.writeInt(u32, functions.InitConnection.cid, .little);
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
