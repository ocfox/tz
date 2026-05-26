const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tcp = @import("transport/tcp.zig");
const session_mod = @import("session/message.zig");
const codec = @import("codec");
const types = @import("types");

// MTProto internal IDs not in schema
const cid_msg_container: u32 = 0x73f1f8dc;
const cid_rpc_result: u32 = 0xf35c6d01;
const cid_gzip_packed: u32 = 0x3072cfa1;

const PendingRequest = struct {
    buf: [1][]u8,
    queue: std.Io.Queue([]u8),
    plaintext: []const u8 = &.{},

    fn init(self: *PendingRequest) void {
        self.queue = std.Io.Queue([]u8).init(&self.buf);
    }
};

const LoopResult = union(enum) {
    read: anyerror!void,
    write: anyerror!void,
    ping: anyerror!void,
};

/// Low-level MTProto transport over a single TCP connection.
/// Handler must implement: fn onUpdate(self: *Handler, io: Io, payload: []const u8) void
pub fn MtProto(comptime Handler: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        session: session_mod.Session,
        transport: tcp.TcpTransport,
        write_queue: std.Io.Queue([]const u8),
        write_queue_buf: [32][]const u8,
        pending: std.AutoHashMap(i64, *PendingRequest),
        pending_mutex: std.Io.Mutex = .init,
        pong_event: std.Io.Event = .unset,
        select_buf: [3]LoopResult,
        select: ?std.Io.Select(LoopResult) = null,
        handler: *Handler,

        pub fn init(
            allocator: Allocator,
            transport: tcp.TcpTransport,
            session: session_mod.Session,
            handler: *Handler,
        ) !*Self {
            const self = try allocator.create(Self);
            // SAFETY: write_queue_buf/write_queue are initialized by the Queue.init call below;
            //         select_buf is initialized by Select.init inside run() before any use.
            self.* = .{
                .allocator = allocator,
                .session = session,
                .transport = transport,
                .write_queue_buf = undefined,
                .write_queue = undefined,
                .select_buf = undefined,
                .pending = std.AutoHashMap(i64, *PendingRequest).init(allocator),
                .handler = handler,
            };
            self.write_queue = std.Io.Queue([]const u8).init(&self.write_queue_buf);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit();
            self.session.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Start readLoop, writeLoop, pingLoop concurrently. Call join() to wait.
        pub fn run(self: *Self, io: Io) !void {
            self.select = std.Io.Select(LoopResult).init(io, &self.select_buf);
            try self.select.?.concurrent(.read, readLoop, .{ self, io });
            try self.select.?.concurrent(.write, writeLoop, .{ self, io });
            try self.select.?.concurrent(.ping, pingLoop, .{ self, io });
        }

        /// Threadsafe. Signals the connection to close.
        pub fn close(self: *Self, io: Io) void {
            self.write_queue.close(io);
            self.pong_event.set(io);
        }

        /// Block until all loops exit. Safe to call multiple times.
        pub fn join(self: *Self) void {
            const s = &(self.select orelse return);
            _ = s.await() catch |err| std.log.debug("select await: {}", .{err});
            s.cancelDiscard();
            self.select = null;
        }

        /// Send a serialized TL request, return the raw response bytes (caller frees).
        pub fn call(self: *Self, io: Io, request: []const u8) ![]u8 {
            // SAFETY: pr.init() initializes buf and queue immediately below
            var pr: PendingRequest = undefined;
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
                return err;
            };
            self.allocator.free(pr.plaintext);
            return result;
        }

        fn readLoop(self: *Self, io: Io) !void {
            defer self.drainPending(io);
            while (true) {
                const frame = self.transport.readFrame(io, self.allocator) catch |err| {
                    std.log.debug("readLoop: readFrame failed: {}", .{err});
                    break;
                };
                defer self.allocator.free(frame);
                const payload = self.session.decrypt(frame, self.allocator) catch |e| {
                    std.log.debug("readLoop: decrypt failed: {}", .{e});
                    continue;
                };
                defer self.allocator.free(payload);
                self.dispatch(io, payload) catch |err| std.log.debug("dispatch: {}", .{err});
            }
        }

        fn dispatch(self: *Self, io: Io, payload: []const u8) anyerror!void {
            if (payload.len < 4) return;
            const cid = std.mem.readInt(u32, payload[0..4], .little);
            std.log.debug("recv cid=0x{x:0>8}", .{cid});
            switch (cid) {
                cid_msg_container => try self.dispatchContainer(io, payload),
                cid_rpc_result => try self.deliverRpcResult(io, payload),
                cid_gzip_packed => {
                    var r: std.Io.Reader = .fixed(payload[4..]);
                    const compressed = try codec.deserialize.bytes(&r, self.allocator);
                    defer self.allocator.free(compressed);
                    var in = std.Io.Reader.fixed(compressed);
                    var aw: std.Io.Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
                    _ = try decomp.reader.streamRemaining(&aw.writer);
                    try self.dispatch(io, aw.written());
                },
                types.MsgsAck.cid => {},
                types.NewSessionCreated.cid => {
                    if (payload.len >= 28) {
                        self.session.server_salt = std.mem.readInt(i64, payload[20..28], .little);
                    }
                },
                types.BadServerSalt.cid => {
                    if (payload.len >= 28) {
                        const new_salt = std.mem.readInt(i64, payload[20..28], .little);
                        self.session.server_salt = new_salt;
                        std.log.debug("bad_server_salt, updated salt, retrying {} pending", .{self.pending.count()});
                        self.pong_event.set(io);
                        self.retryPending(io);
                    } else {
                        std.log.warn("bad_server_salt: payload too short, draining", .{});
                        self.drainPending(io);
                    }
                },
                types.BadMsgNotification_.cid => {
                    if (payload.len >= 20) {
                        const error_code = std.mem.readInt(i32, payload[16..20], .little);
                        std.log.warn("bad_msg_notification error_code={}", .{error_code});
                        switch (error_code) {
                            // Msg ID / seqno issues: retry with corrected values.
                            16, 17, 18, 19, 20, 32, 33 => self.retryPending(io),
                            else => self.drainPending(io),
                        }
                    } else {
                        std.log.warn("bad_msg_notification (short payload)", .{});
                        self.drainPending(io);
                    }
                },
                types.Pong.cid => {
                    self.pong_event.set(io);
                },
                else => {
                    self.handler.onUpdate(io, payload);
                },
            }
        }

        fn dispatchContainer(self: *Self, io: Io, payload: []const u8) !void {
            if (payload.len < 8) return;
            const count = std.mem.readInt(u32, payload[4..8], .little);
            var pos: usize = 8;
            for (0..count) |_| {
                if (pos + 16 > payload.len) break;
                const bytes = std.mem.readInt(u32, payload[pos + 12 ..][0..4], .little);
                const body_end = pos + 16 + bytes;
                if (body_end > payload.len) break;
                self.dispatch(io, payload[pos + 16 .. body_end]) catch |err| std.log.debug("dispatch: {}", .{err});
                pos = body_end;
            }
        }

        fn deliverRpcResult(self: *Self, io: Io, payload: []const u8) !void {
            if (payload.len < 12) return;
            const req_msg_id = std.mem.readInt(i64, payload[4..12], .little);
            const pr = blk: {
                self.pending_mutex.lockUncancelable(io);
                defer self.pending_mutex.unlock(io);
                const e = self.pending.fetchRemove(req_msg_id) orelse {
                    std.log.debug("deliverRpcResult: no pending for msg_id={x}", .{req_msg_id});
                    return;
                };
                break :blk e.value;
            };
            const result = try self.allocator.dupe(u8, payload[12..]);
            try pr.queue.putOne(io, result);
        }

        fn retryPending(self: *Self, io: Io) void {
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

        fn drainPending(self: *Self, io: Io) void {
            self.pending_mutex.lockUncancelable(io);
            defer self.pending_mutex.unlock(io);
            var it = self.pending.valueIterator();
            while (it.next()) |pr| pr.*.queue.close(io);
            self.pending.clearRetainingCapacity();
        }

        fn writeLoop(self: *Self, io: Io) !void {
            while (true) {
                const data = self.write_queue.getOne(io) catch break;
                defer self.allocator.free(data);
                self.transport.writeFrame(io, data) catch break;
            }
        }

        fn pingLoop(self: *Self, io: Io) anyerror!void {
            const funcs = @import("functions");
            while (true) {
                std.Io.sleep(io, std.Io.Duration.fromSeconds(60), .awake) catch break;

                var ping_id_bytes: [8]u8 = undefined;
                io.random(&ping_id_bytes);
                const ping_id = std.mem.readInt(i64, &ping_id_bytes, .little);

                const bytes = codec.encodeAlloc(
                    funcs.PingDelayDisconnect{ .ping_id = ping_id, .disconnect_delay = 75 },
                    self.allocator,
                ) catch break;
                defer self.allocator.free(bytes);
                self.pong_event.reset();
                const enc = self.session.encrypt(bytes, self.allocator, io) catch break;
                self.write_queue.putOne(io, enc.data) catch {
                    self.allocator.free(enc.data);
                    break;
                };
                self.pong_event.waitTimeout(io, .{ .duration = .{
                    .raw = std.Io.Duration.fromSeconds(15),
                    .clock = .awake,
                } }) catch {
                    std.log.warn("ping timeout", .{});
                    break;
                };
            }
        }
    };
}
