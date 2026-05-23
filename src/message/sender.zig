const std = @import("std");
const Io = std.Io;
const Client = @import("../client.zig").Client;
const Entities = @import("../dispatcher.zig").Entities;
const types = @import("types");
const functions = @import("functions");

var random_counter = std.atomic.Value(i64).init(0);

pub fn initRandomCounter() void {
    var seed: [32]u8 = undefined;
    _ = std.os.linux.getrandom(&seed, seed.len, 0);
    var csprng = std.Random.DefaultCsprng.init(seed);
    random_counter.store(csprng.random().int(i64), .monotonic);
}

fn nextRandomId() i64 {
    return random_counter.fetchAdd(1, .monotonic);
}

pub const RequestBuilder = struct {
    client: *Client,
    peer: types.InputPeer,

    pub fn text(self: RequestBuilder, io: Io, msg: []const u8) !void {
        _ = try self.client.call(io, functions.messages.SendMessage{
            .flags = .{},
            .peer = self.peer,
            .message = msg,
            .random_id = nextRandomId(),
        });
    }
};

pub const Sender = struct {
    client: *Client,

    pub fn init(client: *Client) Sender {
        return .{ .client = client };
    }

    /// Build a reply to an UpdateNewMessage. Returns null if peer cannot be resolved.
    pub fn reply(
        self: Sender,
        entities: Entities,
        update: types.UpdateNewMessage,
    ) ?RequestBuilder {
        const msg = switch (update.message) {
            .Message => |m| m,
            else => return null,
        };
        const peer: types.InputPeer = switch (msg.peer_id) {
            .PeerUser => |p| .{ .InputPeerUser = .{
                .user_id = p.user_id,
                .access_hash = entities.accessHash(p.user_id) orelse return null,
            } },
            else => return null,
        };
        return .{ .client = self.client, .peer = peer };
    }
};
