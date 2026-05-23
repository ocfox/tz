const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const conn_mod = @import("conn.zig");
const UpdateHandler = conn_mod.UpdateHandler;
const codec = @import("codec");
const Client = @import("client.zig").Client;

pub const Entities = struct {
    users: std.AutoHashMapUnmanaged(i64, i64) = .empty, // user_id → access_hash

    pub fn deinit(self: *Entities, allocator: Allocator) void {
        self.users.deinit(allocator);
    }

    pub fn accessHash(self: *const Entities, user_id: i64) ?i64 {
        return self.users.get(user_id);
    }
};

const HandlerEntry = struct {
    // body_ptr points to the decoded Update struct (type-erased)
    dispatchFn: *const fn (client: *Client, io: Io, entities: Entities, body_ptr: *const anyopaque, allocator: Allocator) anyerror!void,
};

pub const Dispatcher = struct {
    allocator: Allocator,
    handlers: std.AutoHashMap(u32, HandlerEntry),
    client: ?*Client = null,

    pub fn init(allocator: Allocator) Dispatcher {
        return .{
            .allocator = allocator,
            .handlers = std.AutoHashMap(u32, HandlerEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.handlers.deinit();
    }

    pub fn bindClient(self: *Dispatcher, client: *Client) void {
        self.client = client;
    }

    pub fn on(
        self: *Dispatcher,
        comptime Update: type,
        comptime cb: *const fn (*Client, Io, Entities, Update) anyerror!void,
    ) !void {
        const Wrap = struct {
            fn dispatch(client: *Client, io: Io, entities: Entities, body_ptr: *const anyopaque, allocator: Allocator) anyerror!void {
                _ = allocator;
                const update: *const Update = @ptrCast(@alignCast(body_ptr));
                try cb(client, io, entities, update.*);
            }
        };
        try self.handlers.put(Update.cid, .{ .dispatchFn = Wrap.dispatch });
    }

    pub fn handler(self: *Dispatcher) UpdateHandler {
        return .{
            .ptr = self,
            .vtable = &.{ .handle = dispatchRaw },
        };
    }

    fn dispatchRaw(ptr: *anyopaque, io: Io, payload: []const u8) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(ptr));
        if (payload.len < 4) return;
        const cid = std.mem.readInt(u32, payload[0..4], .little);
        if (cid == 0x74ae4240) {
            self.dispatchUpdates(io, payload) catch {};
        }
        // Other top-level constructors (e.g. bare RPC results) are ignored here;
        // they are handled via client.call's response path.
    }

    fn dispatchUpdates(self: *Dispatcher, io: Io, payload: []const u8) !void {
        const client = self.client orelse return error.DispatcherNotBound;
        const types = @import("types");
        var r: std.Io.Reader = .fixed(payload[4..]);
        const upd = try codec.decodeStructBody(types.Updates_, &r, self.allocator);

        var entities: Entities = .{};
        defer entities.deinit(self.allocator);
        for (upd.users) |u| switch (u) {
            .User => |user| if (user.access_hash.value) |ah|
                try entities.users.put(self.allocator, user.id, ah),
            else => {},
        };

        for (upd.updates) |u| {
            // Pass pointer to the already-decoded update body directly — no re-encode.
            switch (u) {
                inline else => |*body| {
                    const entry = self.handlers.get(@TypeOf(body.*).cid) orelse continue;
                    entry.dispatchFn(client, io, entities, body, self.allocator) catch |err|
                        std.log.warn("handler error: {}", .{err});
                },
            }
        }
    }
};
