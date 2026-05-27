const std = @import("std");
const types = @import("types");
const PeerCache = @This();

pub const Kind = enum { user, chat, channel };

pub const Entry = struct {
    access_hash: i64,
    kind: Kind,
    min: bool,
};

map: std.AutoHashMapUnmanaged(i64, Entry) = .empty,

pub fn deinit(self: *PeerCache, gpa: std.mem.Allocator) void {
    self.map.deinit(gpa);
}

fn put(self: *PeerCache, gpa: std.mem.Allocator, id: i64, e: Entry) !void {
    const gop = try self.map.getOrPut(gpa, id);
    if (gop.found_existing) {
        // min must not overwrite non-min.
        if (e.min and !gop.value_ptr.min) return;
    }
    gop.value_ptr.* = e;
}

pub fn update(
    self: *PeerCache,
    gpa: std.mem.Allocator,
    users: []const types.User,
    chats: []const types.Chat,
) !void {
    for (users) |u| switch (u) {
        .User => |user| if (user.access_hash.value) |ah|
            try self.put(gpa, user.id, .{ .access_hash = ah, .kind = .user, .min = user.min.value != null }),
        else => {},
    };
    for (chats) |c| switch (c) {
        .Channel => |ch| if (ch.access_hash.value) |ah|
            try self.put(gpa, ch.id, .{ .access_hash = ah, .kind = .channel, .min = ch.min.value != null }),
        .Chat => |chat| try self.put(gpa, chat.id, .{ .access_hash = 0, .kind = .chat, .min = false }),
        else => {},
    };
}

pub fn inputPeer(self: *const PeerCache, id: i64) ?types.InputPeer {
    const e = self.map.get(id) orelse return null;
    return switch (e.kind) {
        .user => .{ .InputPeerUser = .{ .user_id = id, .access_hash = e.access_hash } },
        .channel => .{ .InputPeerChannel = .{ .channel_id = id, .access_hash = e.access_hash } },
        .chat => .{ .InputPeerChat = .{ .chat_id = id } },
    };
}

pub fn inputUser(self: *const PeerCache, id: i64) ?types.InputUser {
    const e = self.map.get(id) orelse return null;
    if (e.kind != .user) return null;
    return .{ .InputUser = .{ .user_id = id, .access_hash = e.access_hash } };
}

pub fn inputChannel(self: *const PeerCache, id: i64) ?types.InputChannel {
    const e = self.map.get(id) orelse return null;
    if (e.kind != .channel) return null;
    return .{ .InputChannel = .{ .channel_id = id, .access_hash = e.access_hash } };
}

test "min peer does not overwrite non-min" {
    const gpa = std.testing.allocator;
    var pc = PeerCache{};
    defer pc.deinit(gpa);

    const full = [_]types.User{.{ .User = .{ .id = 10, .access_hash = .{ .value = 1234 } } }};
    try pc.update(gpa, &full, &.{});
    var min_user = types.User_{ .id = 10, .access_hash = .{ .value = 9999 } };
    min_user.min = .some({});
    const min = [_]types.User{.{ .User = min_user }};
    try pc.update(gpa, &min, &.{});

    const ip = pc.inputPeer(10).?;
    try std.testing.expectEqual(@as(i64, 1234), ip.InputPeerUser.access_hash);
}

test "inputChannel resolves from chats" {
    const gpa = std.testing.allocator;
    var pc = PeerCache{};
    defer pc.deinit(gpa);
    const chats = [_]types.Chat{.{ .Channel = .{ .id = 77, .access_hash = .{ .value = 555 }, .title = "c", .photo = undefined, .date = 0 } }};
    try pc.update(gpa, &.{}, &chats);
    const ic = pc.inputChannel(77).?;
    try std.testing.expectEqual(@as(i64, 77), ic.InputChannel.channel_id);
    try std.testing.expectEqual(@as(i64, 555), ic.InputChannel.access_hash);
}
