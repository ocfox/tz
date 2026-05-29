const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const MessageBox = @This();
const ulog = std.log.scoped(.updates);

pub const ChannelState = struct { pts: i32, access_hash: i64 };

pub const Entry = union(enum) {
    common,
    channel: i64,
};

pub const PtsInfo = struct {
    entry: Entry,
    pts: i32,
    count: i32,
};

fn messageChannelId(msg: types.Message) ?i64 {
    const peer = switch (msg) {
        .Message => |m| m.peer_id,
        .MessageService => |m| m.peer_id,
        .MessageEmpty => |m| m.peer_id.value orelse return null,
    };
    return switch (peer) {
        .PeerChannel => |pc| pc.channel_id,
        else => null,
    };
}

/// Unwrap a field that may be either a plain integer or a `tl.Flag(..)`-wrapped
/// optional. Returns null when the value is an absent optional flag.
fn flagValue(comptime V: type, v: anytype) ?V {
    const F = @TypeOf(v);
    if (F == V) return v;
    // tl.Flag(..) wrappers expose a `.value` of type `?V`.
    if (@hasField(F, "value")) return v.value;
    return @as(?V, null);
}

pub fn ptsInfo(u: types.Update) ?PtsInfo {
    switch (u) {
        inline else => |body, tag| {
            const T = @TypeOf(body);
            if (@typeInfo(T) != .@"struct") return null;
            if (@hasField(T, "qts")) {
                const qts = flagValue(i32, body.qts) orelse return null;
                return .{ .entry = .common, .pts = qts, .count = 1 };
            }
            if (!@hasField(T, "pts")) return null;
            const pts = flagValue(i32, body.pts) orelse return null;
            const count: i32 = if (@hasField(T, "pts_count")) (flagValue(i32, body.pts_count) orelse 0) else 0;
            if (@hasField(T, "channel_id")) {
                const cid = flagValue(i64, body.channel_id) orelse return null;
                return .{ .entry = .{ .channel = cid }, .pts = pts, .count = count };
            }
            if (tag == .UpdateNewChannelMessage or tag == .UpdateEditChannelMessage) {
                if (messageChannelId(body.message)) |cid|
                    return .{ .entry = .{ .channel = cid }, .pts = pts, .count = count };
            }
            return .{ .entry = .common, .pts = pts, .count = count };
        },
    }
}

pts: i32 = 0,
qts: i32 = 0,
date: i32 = 0,
seq: i32 = 0,
channels: std.AutoHashMapUnmanaged(i64, ChannelState) = .empty,

/// common difference fetch pending.
getting_diff: bool = false,
/// channels with a pending difference fetch.
getting_channel_diff: std.AutoHashMapUnmanaged(i64, void) = .empty,

pub fn deinit(self: *MessageBox, gpa: std.mem.Allocator) void {
    self.channels.deinit(gpa);
    self.getting_channel_diff.deinit(gpa);
}

const blob_version: u16 = 1;

pub fn serialize(self: *const MessageBox, w: *std.Io.Writer) !void {
    try w.writeInt(u16, blob_version, .little);
    try w.writeInt(i32, self.pts, .little);
    try w.writeInt(i32, self.qts, .little);
    try w.writeInt(i32, self.date, .little);
    try w.writeInt(i32, self.seq, .little);
    try w.writeInt(u32, self.channels.count(), .little);
    var it = self.channels.iterator();
    while (it.next()) |kv| {
        try w.writeInt(i64, kv.key_ptr.*, .little);
        try w.writeInt(i32, kv.value_ptr.pts, .little);
        try w.writeInt(i64, kv.value_ptr.access_hash, .little);
    }
}

/// On failure the caller should reset to an empty MessageBox (corrupt blob).
pub fn deserialize(self: *MessageBox, gpa: std.mem.Allocator, r: *std.Io.Reader) !void {
    if (try r.takeInt(u16, .little) != blob_version) return error.UnsupportedVersion;
    self.pts = try r.takeInt(i32, .little);
    self.qts = try r.takeInt(i32, .little);
    self.date = try r.takeInt(i32, .little);
    self.seq = try r.takeInt(i32, .little);
    const count = try r.takeInt(u32, .little);
    for (0..count) |_| {
        const id = try r.takeInt(i64, .little);
        const pts = try r.takeInt(i32, .little);
        const ah = try r.takeInt(i64, .little);
        try self.channels.put(gpa, id, .{ .pts = pts, .access_hash = ah });
    }
}

test "serialize/deserialize roundtrip" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    mb.pts = 100;
    mb.qts = 5;
    mb.date = 1234;
    mb.seq = 7;
    try mb.channels.put(gpa, 555, .{ .pts = 42, .access_hash = 888 });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try mb.serialize(&aw.writer);

    var mb2 = MessageBox{};
    defer mb2.deinit(gpa);
    var r: std.Io.Reader = .fixed(aw.written());
    try mb2.deserialize(gpa, &r);

    try std.testing.expectEqual(@as(i32, 100), mb2.pts);
    try std.testing.expectEqual(@as(i32, 5), mb2.qts);
    try std.testing.expectEqual(@as(i32, 7), mb2.seq);
    try std.testing.expectEqual(@as(i32, 42), mb2.channels.get(555).?.pts);
    try std.testing.expectEqual(@as(i64, 888), mb2.channels.get(555).?.access_hash);
}

test "ptsInfo: common message update" {
    const u = types.Update{ .UpdateNewMessage = .{
        .message = .{ .MessageEmpty = .{ .id = 1 } },
        .pts = 50,
        .pts_count = 1,
    } };
    const info = MessageBox.ptsInfo(u).?;
    try std.testing.expectEqual(Entry.common, info.entry);
    try std.testing.expectEqual(@as(i32, 50), info.pts);
    try std.testing.expectEqual(@as(i32, 1), info.count);
}

test "ptsInfo: channel update via explicit channel_id" {
    const u = types.Update{ .UpdateDeleteChannelMessages = .{
        .channel_id = 999,
        .messages = &.{},
        .pts = 12,
        .pts_count = 1,
    } };
    const info = MessageBox.ptsInfo(u).?;
    try std.testing.expectEqual(@as(i64, 999), info.entry.channel);
    try std.testing.expectEqual(@as(i32, 12), info.pts);
}

test "ptsInfo: channel message via message.peer_id" {
    const u = types.Update{ .UpdateNewChannelMessage = .{
        .message = .{ .Message = .{
            .id = 1,
            .peer_id = .{ .PeerChannel = .{ .channel_id = 321 } },
            .date = 0,
            .message = "hi",
        } },
        .pts = 8,
        .pts_count = 1,
    } };
    const info = MessageBox.ptsInfo(u).?;
    try std.testing.expectEqual(@as(i64, 321), info.entry.channel);
}

test "ptsInfo: no pts returns null" {
    const u = types.Update{ .UpdateChannelUserTyping = .{
        .channel_id = 1,
        .from_id = .{ .PeerUser = .{ .user_id = 2 } },
        .action = .{ .SendMessageTypingAction = .{} },
    } };
    try std.testing.expect(MessageBox.ptsInfo(u) == null);
}

pub const ProcessResult = struct {
    /// updates ready to apply, in confirmed order (arena-owned).
    applied: []types.Update,
};

fn localPts(self: *MessageBox, entry: Entry) ?i32 {
    return switch (entry) {
        .common => self.pts,
        .channel => |id| if (self.channels.get(id)) |c| c.pts else null,
    };
}

fn setLocalPts(self: *MessageBox, gpa: std.mem.Allocator, entry: Entry, pts: i32) !void {
    switch (entry) {
        .common => self.pts = pts,
        .channel => |id| {
            const gop = try self.channels.getOrPut(gpa, id);
            if (gop.found_existing) {
                gop.value_ptr.pts = pts;
            } else {
                gop.value_ptr.* = .{ .pts = pts, .access_hash = 0 };
            }
        },
    }
}

fn markGap(self: *MessageBox, gpa: std.mem.Allocator, entry: Entry) !void {
    switch (entry) {
        .common => self.getting_diff = true,
        .channel => |id| try self.getting_channel_diff.put(gpa, id, {}),
    }
}

fn lessByPts(_: void, a: types.Update, b: types.Update) bool {
    const pa = if (ptsInfo(a)) |i| i.pts - i.count else std.math.minInt(i32);
    const pb = if (ptsInfo(b)) |i| i.pts - i.count else std.math.minInt(i32);
    return pa < pb;
}

/// Sorts updates by pts ascending and applies those without gaps.
/// On gap, marks the entry and skips that update.
pub fn processUpdates(
    self: *MessageBox,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    updates: []const types.Update,
) !ProcessResult {
    const sorted = try arena.dupe(types.Update, updates);
    std.sort.pdq(types.Update, sorted, {}, lessByPts);

    var applied: std.ArrayListUnmanaged(types.Update) = .empty;
    for (sorted) |u| {
        const tag = @tagName(u);
        const info = ptsInfo(u) orelse {
            ulog.debug("apply (no pts) {s}", .{tag});
            try applied.append(arena, u);
            continue;
        };
        const gapping = switch (info.entry) {
            .common => self.getting_diff,
            .channel => |id| self.getting_channel_diff.contains(id),
        };
        if (gapping) {
            ulog.debug("skip (gap pending) {s} entry={} pts={}", .{ tag, info.entry, info.pts });
            continue;
        }

        const local = self.localPts(info.entry) orelse {
            ulog.debug("gap (unknown entry) {s} entry={} pts={}", .{ tag, info.entry, info.pts });
            try self.markGap(gpa, info.entry);
            continue;
        };
        const expected = local + info.count;
        if (info.pts <= local) {
            ulog.debug("dup {s} entry={} pts={} <= local={}", .{ tag, info.entry, info.pts, local });
            continue;
        } else if (info.pts == expected) {
            ulog.debug("apply {s} entry={} pts={} (local {} -> {})", .{ tag, info.entry, info.pts, local, info.pts });
            try self.setLocalPts(gpa, info.entry, info.pts);
            try applied.append(arena, u);
        } else {
            ulog.debug("gap {s} entry={} pts={} count={} local={} expected={}", .{
                tag, info.entry, info.pts, info.count, local, expected,
            });
            try self.markGap(gpa, info.entry);
        }
    }
    return .{ .applied = try applied.toOwnedSlice(arena) };
}

test "processUpdates: in-order applies, advances pts" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    mb.pts = 10;
    const ups = [_]types.Update{.{ .UpdateNewMessage = .{
        .message = .{ .MessageEmpty = .{ .id = 1 } },
        .pts = 11,
        .pts_count = 1,
    } }};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = try mb.processUpdates(gpa, arena.allocator(), &ups);
    try std.testing.expectEqual(@as(usize, 1), res.applied.len);
    try std.testing.expectEqual(@as(i32, 11), mb.pts);
    try std.testing.expect(!mb.getting_diff);
}

test "processUpdates: gap marks getting_diff, does not apply" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    mb.pts = 10;
    const ups = [_]types.Update{.{ .UpdateNewMessage = .{
        .message = .{ .MessageEmpty = .{ .id = 1 } },
        .pts = 15,
        .pts_count = 1,
    } }};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = try mb.processUpdates(gpa, arena.allocator(), &ups);
    try std.testing.expectEqual(@as(usize, 0), res.applied.len);
    try std.testing.expect(mb.getting_diff);
    try std.testing.expectEqual(@as(i32, 10), mb.pts);
}

test "processUpdates: duplicate (pts <= local) skipped" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    mb.pts = 20;
    const ups = [_]types.Update{.{ .UpdateNewMessage = .{
        .message = .{ .MessageEmpty = .{ .id = 1 } },
        .pts = 18,
        .pts_count = 1,
    } }};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = try mb.processUpdates(gpa, arena.allocator(), &ups);
    try std.testing.expectEqual(@as(usize, 0), res.applied.len);
    try std.testing.expect(!mb.getting_diff);
}

test "processUpdates: no-pts update always applied" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    const ups = [_]types.Update{.{ .UpdateChannelUserTyping = .{
        .channel_id = 1,
        .from_id = .{ .PeerUser = .{ .user_id = 2 } },
        .action = .{ .SendMessageTypingAction = .{} },
    } }};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = try mb.processUpdates(gpa, arena.allocator(), &ups);
    try std.testing.expectEqual(@as(usize, 1), res.applied.len);
}

pub fn setState(self: *MessageBox, st: types.UpdatesState) void {
    self.pts = st.pts;
    self.qts = st.qts;
    self.date = st.date;
    self.seq = st.seq;
}

pub const Request = union(enum) {
    common: functions.updates.GetDifference,
    channel: struct { id: i64, req: functions.updates.GetChannelDifference },
};

/// Stop tracking a channel entirely — drops both the pending gap and its pts state.
/// Used when the server reports the channel is inaccessible (CHANNEL_INVALID), where
/// retrying the difference would loop forever.
pub fn dropChannel(self: *MessageBox, id: i64) void {
    _ = self.getting_channel_diff.remove(id);
    _ = self.channels.remove(id);
}

/// Returns a pending difference request if any gap is set. Common takes priority.
/// For channel requests the caller must resolve access_hash (channel field is Empty here).
pub fn takeDifferenceRequest(self: *MessageBox) ?Request {
    if (self.getting_diff) {
        return .{ .common = .{ .pts = self.pts, .date = self.date, .qts = self.qts } };
    }
    var it = self.getting_channel_diff.keyIterator();
    if (it.next()) |id_ptr| {
        const id = id_ptr.*;
        const cs = self.channels.get(id) orelse return null;
        return .{ .channel = .{ .id = id, .req = .{
            .channel = .{ .InputChannelEmpty = .{} },
            .filter = .{ .ChannelMessagesFilterEmpty = .{} },
            .pts = cs.pts,
            .limit = 100,
        } } };
    }
    return null;
}

pub const DiffApplied = struct {
    updates: []types.Update,
    users: []const types.User,
    chats: []const types.Chat,
    /// true if this was a partial slice and the difference loop must continue.
    has_more: bool,
};

/// Wraps new_messages as UpdateNewMessage (pts=0; state already advanced via setState)
/// and concatenates other_updates. These are dispatched directly (not re-run through processUpdates).
fn diffToUpdates(
    arena: std.mem.Allocator,
    new_messages: []const types.Message,
    other: []const types.Update,
) ![]types.Update {
    var list: std.ArrayListUnmanaged(types.Update) = .empty;
    for (new_messages) |m| {
        try list.append(arena, .{ .UpdateNewMessage = .{ .message = m, .pts = 0, .pts_count = 0 } });
    }
    try list.appendSlice(arena, other);
    return list.toOwnedSlice(arena);
}

pub fn applyDifference(
    self: *MessageBox,
    arena: std.mem.Allocator,
    diff: types.UpdatesDifference,
) !DiffApplied {
    switch (diff) {
        .UpdatesDifferenceEmpty => |e| {
            self.date = e.date;
            self.seq = e.seq;
            self.getting_diff = false;
            return .{ .updates = &.{}, .users = &.{}, .chats = &.{}, .has_more = false };
        },
        .UpdatesDifference => |d| {
            self.setState(d.state);
            self.getting_diff = false;
            const ups = try diffToUpdates(arena, d.new_messages, d.other_updates);
            return .{ .updates = ups, .users = d.users, .chats = d.chats, .has_more = false };
        },
        .UpdatesDifferenceSlice => |d| {
            self.setState(d.intermediate_state);
            const ups = try diffToUpdates(arena, d.new_messages, d.other_updates);
            return .{ .updates = ups, .users = d.users, .chats = d.chats, .has_more = true };
        },
        .UpdatesDifferenceTooLong => |d| {
            self.pts = d.pts;
            return .{ .updates = &.{}, .users = &.{}, .chats = &.{}, .has_more = true };
        },
    }
}

test "setState then takeDifferenceRequest none when no gap" {
    var mb = MessageBox{};
    defer mb.deinit(std.testing.allocator);
    mb.setState(.{ .pts = 5, .qts = 1, .date = 100, .seq = 2, .unread_count = 0 });
    try std.testing.expectEqual(@as(i32, 5), mb.pts);
    try std.testing.expect(mb.takeDifferenceRequest() == null);
}

test "common gap produces GetDifference request" {
    var mb = MessageBox{};
    defer mb.deinit(std.testing.allocator);
    mb.setState(.{ .pts = 5, .qts = 1, .date = 100, .seq = 2, .unread_count = 0 });
    mb.getting_diff = true;
    const req = mb.takeDifferenceRequest().?;
    try std.testing.expectEqual(@as(i32, 5), req.common.pts);
    try std.testing.expectEqual(@as(i32, 1), req.common.qts);
    try std.testing.expectEqual(@as(i32, 100), req.common.date);
}

test "applyDifference advances state and clears gap" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    mb.setState(.{ .pts = 5, .qts = 1, .date = 100, .seq = 2, .unread_count = 0 });
    mb.getting_diff = true;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diff = types.UpdatesDifference{ .UpdatesDifference = .{
        .new_messages = &.{},
        .new_encrypted_messages = &.{},
        .other_updates = &.{},
        .chats = &.{},
        .users = &.{},
        .state = .{ .pts = 9, .qts = 1, .date = 200, .seq = 3, .unread_count = 0 },
    } };
    const res = try mb.applyDifference(arena.allocator(), diff);
    try std.testing.expectEqual(@as(i32, 9), mb.pts);
    try std.testing.expect(!mb.getting_diff);
    _ = res;
}

fn setChannelPts(self: *MessageBox, gpa: std.mem.Allocator, id: i64, pts: i32) !void {
    const gop = try self.channels.getOrPut(gpa, id);
    if (gop.found_existing) {
        gop.value_ptr.pts = pts;
    } else {
        gop.value_ptr.* = .{ .pts = pts, .access_hash = 0 };
    }
}

pub fn applyChannelDifference(
    self: *MessageBox,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    channel_id: i64,
    diff: types.UpdatesChannelDifference,
) !DiffApplied {
    switch (diff) {
        .UpdatesChannelDifferenceEmpty => |d| {
            try self.setChannelPts(gpa, channel_id, d.pts);
            _ = self.getting_channel_diff.remove(channel_id);
            return .{ .updates = &.{}, .users = &.{}, .chats = &.{}, .has_more = false };
        },
        .UpdatesChannelDifference => |d| {
            try self.setChannelPts(gpa, channel_id, d.pts);
            const final = d.final.value != null;
            if (final) _ = self.getting_channel_diff.remove(channel_id);
            const ups = try diffToUpdates(arena, d.new_messages, d.other_updates);
            return .{ .updates = ups, .users = d.users, .chats = d.chats, .has_more = !final };
        },
        .UpdatesChannelDifferenceTooLong => {
            _ = self.getting_channel_diff.remove(channel_id);
            return .{ .updates = &.{}, .users = &.{}, .chats = &.{}, .has_more = false };
        },
    }
}

test "applyChannelDifference advances channel pts and clears gap" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    try mb.channels.put(gpa, 77, .{ .pts = 3, .access_hash = 111 });
    try mb.getting_channel_diff.put(gpa, 77, {});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diff = types.UpdatesChannelDifference{ .UpdatesChannelDifference = .{
        .final = .some({}),
        .pts = 8,
        .new_messages = &.{},
        .other_updates = &.{},
        .chats = &.{},
        .users = &.{},
    } };
    const res = try mb.applyChannelDifference(gpa, arena.allocator(), 77, diff);
    try std.testing.expectEqual(@as(i32, 8), mb.channels.get(77).?.pts);
    try std.testing.expect(!mb.getting_channel_diff.contains(77));
    try std.testing.expect(!res.has_more);
}

test "non-final channel difference keeps gap for more" {
    const gpa = std.testing.allocator;
    var mb = MessageBox{};
    defer mb.deinit(gpa);
    try mb.channels.put(gpa, 77, .{ .pts = 3, .access_hash = 111 });
    try mb.getting_channel_diff.put(gpa, 77, {});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diff = types.UpdatesChannelDifference{ .UpdatesChannelDifference = .{
        .pts = 8,
        .new_messages = &.{},
        .other_updates = &.{},
        .chats = &.{},
        .users = &.{},
    } };
    const res = try mb.applyChannelDifference(gpa, arena.allocator(), 77, diff);
    try std.testing.expect(res.has_more);
    try std.testing.expect(mb.getting_channel_diff.contains(77));
}
