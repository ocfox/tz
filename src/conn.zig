const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tcp = @import("transport/tcp.zig");
const session_mod = @import("session/message.zig");
const storage_mod = @import("session/storage.zig");
const auth_key_mod = @import("session/auth_key.zig");
const types = @import("types");
const codec = @import("codec");

// MTProto internal IDs not in schema
const cid_msg_container: u32 = 0x73f1f8dc;
const cid_rpc_result: u32 = 0xf35c6d01;

pub const DC = struct {
    id: u8,
    addr: Io.net.IpAddress,
    test_server: bool,
};

pub const default_dcs: []const DC = &.{
    .{ .id = 1, .addr = Io.net.IpAddress.parseIp4("149.154.175.53", 443) catch @panic("bad ip"), .test_server = false },
    .{ .id = 2, .addr = Io.net.IpAddress.parseIp4("149.154.167.41", 443) catch @panic("bad ip"), .test_server = false },
    .{ .id = 3, .addr = Io.net.IpAddress.parseIp4("149.154.175.100", 443) catch @panic("bad ip"), .test_server = false },
    .{ .id = 4, .addr = Io.net.IpAddress.parseIp4("149.154.167.91", 443) catch @panic("bad ip"), .test_server = false },
    .{ .id = 5, .addr = Io.net.IpAddress.parseIp4("91.108.56.191", 443) catch @panic("bad ip"), .test_server = false },
    .{ .id = 1, .addr = Io.net.IpAddress.parseIp4("149.154.175.10", 443) catch @panic("bad ip"), .test_server = true },
    .{ .id = 2, .addr = Io.net.IpAddress.parseIp4("149.154.167.40", 443) catch @panic("bad ip"), .test_server = true },
    .{ .id = 3, .addr = Io.net.IpAddress.parseIp4("149.154.175.117", 443) catch @panic("bad ip"), .test_server = true },
};

pub const TransportMode = enum { tcp_abridged, tcp_intermediate, tcp_padded, websocket };

pub const ConnectOptions = struct {
    dc: DC,
    transport: TransportMode = .tcp_abridged,
    session_storage: storage_mod.SessionStorage,
    api_id: i32,
    api_hash: []const u8,
};

pub const UpdateHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, io: Io, payload: []const u8) anyerror!void,
    };
    pub fn handle(self: UpdateHandler, io: Io, payload: []const u8) !void {
        return self.vtable.handle(self.ptr, io, payload);
    }
};

const PendingRequest = struct {
    buf: [1][]u8 = undefined,
    queue: std.Io.Queue([]u8) = undefined,
    plaintext: []const u8 = &.{}, // original unencrypted request for retry on bad_server_salt

    fn init(self: *PendingRequest) void {
        self.queue = std.Io.Queue([]u8).init(&self.buf);
    }
};

pub const Conn = struct {
    allocator: Allocator,
    session: session_mod.Session,
    transport: tcp.TcpTransport,
    api_id: i32,
    api_hash: []const u8,
    write_queue: std.Io.Queue([]const u8),
    write_queue_buf: [32][]const u8,
    pending: std.AutoHashMap(i64, *PendingRequest),
    pending_mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    initialized: bool = false,
    pong_queue: std.Io.Queue(i64),
    pong_queue_buf: [1]i64,

    pub fn call(self: *Conn, io: Io, request: []const u8) ![]u8 {
        var pr = PendingRequest{};
        pr.init();
        pr.plaintext = try self.allocator.dupe(u8, request);
        errdefer self.allocator.free(pr.plaintext);

        const enc = try self.session.encrypt(request, self.allocator, io);
        var enc_sent = false;
        defer if (!enc_sent) self.allocator.free(enc.data);

        {
            self.pending_mutex.lockUncancelable(io);
            defer self.pending_mutex.unlock(io);
            try self.pending.put(enc.msg_id, &pr);
        }

        self.write_queue.putOne(io, enc.data) catch |err| {
            self.pending_mutex.lockUncancelable(io);
            _ = self.pending.remove(enc.msg_id);
            self.pending_mutex.unlock(io);
            return err;
        };
        enc_sent = true;

        const result = pr.queue.getOne(io) catch |err| {
            self.pending_mutex.lockUncancelable(io);
            _ = self.pending.remove(enc.msg_id);
            self.pending_mutex.unlock(io);
            self.allocator.free(pr.plaintext);
            return err;
        };
        self.allocator.free(pr.plaintext);
        return result;
    }

    pub fn run(self: *Conn, io: Io, handler: UpdateHandler) !void {
        try self.group.concurrent(io, readLoop, .{ self, io, handler });
        try self.group.concurrent(io, writeLoop, .{ self, io });
        try self.group.concurrent(io, pingLoop, .{ self, io });
    }

    pub fn join(self: *Conn, io: Io) void {
        self.group.await(io) catch {};
    }

    pub fn deinit(self: *Conn) void {
        self.pending.deinit();
        self.session.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // Signals the loops to stop. Safe to call multiple times.
    pub fn close(self: *Conn, io: Io) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.write_queue.close(io);
        self.pong_queue.close(io);
        self.transport.stream.close(io); // unblocks readFrame's blocking TCP read
    }

    fn readLoop(self: *Conn, io: Io, handler: UpdateHandler) !void {
        defer self.drainPending(io);
        defer self.close(io);
        while (!self.closed.load(.acquire)) {
            const frame = self.transport.readFrame(io, self.allocator) catch break;
            defer self.allocator.free(frame);
            const payload = self.session.decrypt(frame, self.allocator) catch continue;
            defer self.allocator.free(payload);
            self.dispatch(io, payload, handler) catch {};
        }
    }

    fn dispatch(self: *Conn, io: Io, payload: []const u8, handler: UpdateHandler) anyerror!void {
        if (payload.len < 4) return;
        const cid = std.mem.readInt(u32, payload[0..4], .little);
        std.log.debug("recv cid=0x{x:0>8}", .{cid});
        switch (cid) {
            cid_msg_container => try self.dispatchContainer(io, payload, handler),
            cid_rpc_result => try self.deliverRpcResult(io, payload),
            types.MsgsAck.cid => {},
            types.NewSessionCreated.cid => {
                if (payload.len >= 28) {
                    self.session.server_salt = std.mem.readInt(i64, payload[20..28], .little);
                }
            },
            types.BadServerSalt.cid => {
                // bad_server_salt: cid(4) + bad_msg_id(8) + bad_msg_seqno(4) + error_code(4) + new_server_salt(8)
                if (payload.len >= 28) {
                    const new_salt = std.mem.readInt(i64, payload[20..28], .little);
                    self.session.server_salt = new_salt;
                    std.log.debug("bad_server_salt, updated salt, retrying {} pending", .{self.pending.count()});
                    self.retryPending(io);
                } else {
                    std.log.warn("bad_server_salt: payload too short, draining", .{});
                    self.drainPending(io);
                }
            },
            types.BadMsgNotification_.cid => {
                std.log.warn("bad_msg_notification", .{});
                self.drainPending(io);
            },
            types.Pong.cid => {
                var r: std.Io.Reader = .fixed(payload[4..]);
                const pong = codec.decode(types.Pong, &r, self.allocator) catch return;
                self.pong_queue.putOne(io, pong.ping_id) catch {};
            },
            else => {
            const owned = try self.allocator.dupe(u8, payload);
            errdefer self.allocator.free(owned);
            try self.group.concurrent(io, dispatchUpdate, .{ self, io, handler, owned });
        },
        }
    }

    fn dispatchContainer(self: *Conn, io: Io, payload: []const u8, handler: UpdateHandler) !void {
        if (payload.len < 8) return;
        const count = std.mem.readInt(u32, payload[4..8], .little);
        var pos: usize = 8;
        for (0..count) |_| {
            if (pos + 16 > payload.len) break;
            // msg_id(8) + seqno(4) + bytes(4) + body(bytes)
            const bytes = std.mem.readInt(u32, payload[pos + 12 ..][0..4], .little);
            const body_end = pos + 16 + bytes;
            if (body_end > payload.len) break;
            self.dispatch(io, payload[pos + 16 .. body_end], handler) catch {};
            pos = body_end;
        }
    }

    fn deliverRpcResult(self: *Conn, io: Io, payload: []const u8) !void {
        if (payload.len < 12) return;
        const req_msg_id = std.mem.readInt(i64, payload[4..12], .little);
        const pr = blk: {
            self.pending_mutex.lockUncancelable(io);
            defer self.pending_mutex.unlock(io);
            const e = self.pending.fetchRemove(req_msg_id) orelse return;
            break :blk e.value;
        };
        const result = try self.allocator.dupe(u8, payload[12..]);
        try pr.queue.putOne(io, result);
    }

    fn retryPending(self: *Conn, io: Io) void {
        // Snapshot pending entries, clear map, then re-encrypt and re-send each.
        // We must release the mutex before calling encrypt/write_queue which may block.
        var snap: std.ArrayListUnmanaged(*PendingRequest) = .empty;
        {
            self.pending_mutex.lockUncancelable(io);
            var it = self.pending.valueIterator();
            while (it.next()) |pr| snap.append(self.allocator, pr.*) catch {
                pr.*.queue.close(io);
            };
            self.pending.clearRetainingCapacity();
            self.pending_mutex.unlock(io);
        }
        defer snap.deinit(self.allocator);

        for (snap.items) |pr| {
            const enc = self.session.encrypt(pr.plaintext, self.allocator, io) catch {
                pr.queue.close(io);
                continue;
            };
            {
                self.pending_mutex.lockUncancelable(io);
                self.pending.put(enc.msg_id, pr) catch {
                    self.pending_mutex.unlock(io);
                    self.allocator.free(enc.data);
                    pr.queue.close(io);
                    continue;
                };
                self.pending_mutex.unlock(io);
            }
            self.write_queue.putOne(io, enc.data) catch {
                self.pending_mutex.lockUncancelable(io);
                _ = self.pending.remove(enc.msg_id);
                self.pending_mutex.unlock(io);
                self.allocator.free(enc.data);
                pr.queue.close(io);
            };
        }
    }

    fn drainPending(self: *Conn, io: Io) void {
        self.pending_mutex.lockUncancelable(io);
        defer self.pending_mutex.unlock(io);
        var it = self.pending.valueIterator();
        while (it.next()) |pr| pr.*.queue.close(io);
        self.pending.clearRetainingCapacity();
    }

    fn dispatchUpdate(self: *Conn, io: Io, handler: UpdateHandler, payload: []u8) !void {
        defer self.allocator.free(payload);
        handler.handle(io, payload) catch |err|
            std.log.warn("update handler error: {}", .{err});
    }

    fn writeLoop(self: *Conn, io: Io) !void {
        while (true) {
            const data = self.write_queue.getOne(io) catch break;
            defer self.allocator.free(data);
            self.transport.writeFrame(io, data) catch break;
        }
    }

    fn pingLoop(self: *Conn, io: Io) std.Io.Cancelable!void {
        const funcs = @import("functions");

        const PingSelect = std.Io.Select(union(enum) {
            pong: (std.Io.QueueClosedError || std.Io.Cancelable)!i64,
            timeout: std.Io.Cancelable!void,
        });

        while (!self.closed.load(.acquire)) {
            std.Io.sleep(io, std.Io.Duration.fromSeconds(60), .awake) catch break;
            if (self.closed.load(.acquire)) break;

            // Random ping_id (same approach as gotd)
            var ping_id_bytes: [8]u8 = undefined;
            io.random(&ping_id_bytes);
            const ping_id = std.mem.readInt(i64, &ping_id_bytes, .little);

            // Encode and send ping_delay_disconnect
            const bytes = codec.encodeAlloc(
                funcs.PingDelayDisconnect{ .ping_id = ping_id, .disconnect_delay = 75 },
                self.allocator,
            ) catch break;
            defer self.allocator.free(bytes);
            const enc = self.session.encrypt(bytes, self.allocator, io) catch break;
            self.write_queue.putOne(io, enc.data) catch {
                self.allocator.free(enc.data);
                break;
            };

            // Wait for pong with 15s timeout (gotd: pingTimeout = 15s)
            var sel_buf: [2]PingSelect.Union = undefined;
            var sel = PingSelect.init(io, &sel_buf);
            sel.concurrent(.pong, std.Io.Queue(i64).getOne, .{ &self.pong_queue, io }) catch break;
            sel.async(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(15), .awake });
            const result = sel.await() catch break;
            sel.cancelDiscard();
            switch (result) {
                .pong => {}, // received pong, continue
                .timeout => {
                    std.log.warn("ping timeout, closing connection", .{});
                    self.close(io);
                    break;
                },
            }
        }
    }
};

pub fn connect(io: Io, allocator: Allocator, options: ConnectOptions) !*Conn {
    const stream = try options.dc.addr.connect(io, .{ .mode = .stream });
    var transport = tcp.TcpTransport.init(stream, switch (options.transport) {
        .tcp_abridged => .abridged,
        .tcp_intermediate => .intermediate,
        .tcp_padded => .padded,
        .websocket => .abridged,
    });

    const auth_key_result = blk: {
        if (try options.session_storage.load(io, allocator)) |saved| {
            if (saved.dc_id == options.dc.id) {
                std.log.info("loaded existing session (dc={})", .{saved.dc_id});
                break :blk auth_key_mod.AuthKeyResult{
                    .auth_key = saved.auth_key,
                    .auth_key_id = saved.auth_key_id,
                    .server_salt = saved.server_salt,
                    .time_offset = 0,
                };
            }
            std.log.info("session dc={} != target dc={}, re-doing DH", .{ saved.dc_id, options.dc.id });
        }
        std.log.info("performing DH key exchange", .{});
        const result = try auth_key_mod.perform(&transport, io, allocator);
        std.log.info("DH key exchange complete", .{});
        try options.session_storage.save(io, .{
            .auth_key = result.auth_key,
            .auth_key_id = result.auth_key_id,
            .server_salt = result.server_salt,
            .dc_id = options.dc.id,
        });
        break :blk result;
    };

    const conn = try allocator.create(Conn);
    conn.* = .{
        .allocator = allocator,
        .session = session_mod.Session.init(
            auth_key_result.auth_key,
            auth_key_result.auth_key_id,
            auth_key_result.server_salt,
            io,
        ),
        .transport = transport,
        .api_id = options.api_id,
        .api_hash = options.api_hash,
        .write_queue_buf = undefined,
        .write_queue = undefined,
        .pending = std.AutoHashMap(i64, *PendingRequest).init(allocator),
        .pong_queue_buf = undefined,
        .pong_queue = undefined,
    };
    conn.write_queue = std.Io.Queue([]const u8).init(&conn.write_queue_buf);
    conn.pong_queue = std.Io.Queue(i64).init(&conn.pong_queue_buf);
    return conn;
}
