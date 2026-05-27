const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const client = @import("client.zig");

pub const media = @import("helpers/media.zig");
pub const keyboard = @import("helpers/keyboard.zig");
pub const FormattedText = @import("helpers/FormattedText.zig");

pub const upload = @import("upload.zig").upload;
pub const UploadOptions = @import("upload.zig").UploadOptions;

pub const download = @import("download.zig").download;
pub const documentLocation = @import("download.zig").documentLocation;
pub const photoLocation = @import("download.zig").photoLocation;

pub const ReplyOptions = struct {
    reply_to: ?i32 = null,
    entities: ?[]types.MessageEntity = null,
};

pub const PinOptions = struct {
    silent: bool = false,
    unpin: bool = false,
    pm_oneside: bool = false,
};

pub const EditOptions = struct {
    text: ?[]const u8 = null,
    reply_markup: ?types.ReplyMarkup = null,
};

pub const CallbackAnswerOptions = struct {
    text: ?[]const u8 = null,
    alert: bool = false,
    url: ?[]const u8 = null,
    cache_time: i32 = 0,
};

pub const InlineQueryOptions = struct {
    cache_time: i32 = 300,
    is_gallery: bool = false,
    is_private: bool = false,
    next_offset: ?[]const u8 = null,
};

pub fn reply(ctx: client.Context, update: types.UpdateNewMessage, text: []const u8, opts: ReplyOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    try ctx.exec(functions.messages.SendMessage{
        .peer = peer,
        .message = text,
        .entities = if (opts.entities) |e| .some(e) else .none,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn forwardMessages(ctx: client.Context, from_peer: types.InputPeer, to_peer: types.InputPeer, ids: []i32) !void {
    const random_ids = try ctx.allocator.alloc(i64, ids.len);
    defer ctx.allocator.free(random_ids);
    for (random_ids) |*r| ctx.io.random(std.mem.asBytes(r));
    try ctx.exec(functions.messages.ForwardMessages{
        .from_peer = from_peer,
        .id = ids,
        .random_id = random_ids,
        .to_peer = to_peer,
    });
}

pub fn pinMessage(ctx: client.Context, peer: types.InputPeer, msg_id: i32, opts: PinOptions) !void {
    try ctx.exec(functions.messages.UpdatePinnedMessage{
        .peer = peer,
        .id = msg_id,
        .silent = if (opts.silent) .some({}) else .none,
        .unpin = if (opts.unpin) .some({}) else .none,
        .pm_oneside = if (opts.pm_oneside) .some({}) else .none,
    });
}

pub fn editMessage(ctx: client.Context, peer: types.InputPeer, msg_id: i32, opts: EditOptions) !void {
    try ctx.exec(functions.messages.EditMessage{
        .peer = peer,
        .id = msg_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .reply_markup = if (opts.reply_markup) |m| .some(m) else .none,
    });
}

/// Delete a single message. Uses channels.DeleteMessages for channel peers.
pub fn deleteMessage(ctx: client.Context, peer: types.InputPeer, msg_id: i32) !void {
    var ids = [_]i32{msg_id};
    switch (peer) {
        .InputPeerChannel => |p| {
            const chan = types.InputChannel{ .InputChannel = .{
                .channel_id = p.channel_id,
                .access_hash = p.access_hash,
            } };
            try ctx.exec(functions.channels.DeleteMessages{ .channel = chan, .id = &ids });
        },
        else => try ctx.exec(functions.messages.DeleteMessages{
            .revoke = .some({}),
            .id = &ids,
        }),
    }
}

/// Send a chat action (e.g. SendMessageTypingAction for "typing...").
pub fn sendChatAction(ctx: client.Context, peer: types.InputPeer, action: types.SendMessageAction) !void {
    try ctx.exec(functions.messages.SetTyping{ .peer = peer, .action = action });
}

/// Fetch the bot's own User record. Caller owns the returned slice (ctx.allocator.free).
pub fn getMe(ctx: client.Context) ![]const types.User {
    var id = [_]types.InputUser{.{ .InputUserSelf = .{} }};
    return ctx.call(functions.users.GetUsers{ .id = &id });
}

pub fn answerCallbackQuery(ctx: client.Context, update: types.UpdateBotCallbackQuery, opts: CallbackAnswerOptions) !void {
    try ctx.exec(functions.messages.SetBotCallbackAnswer{
        .alert = if (opts.alert) .some({}) else .none,
        .query_id = update.query_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .url = if (opts.url) |u| .some(u) else .none,
        .cache_time = opts.cache_time,
    });
}

pub fn answerInlineCallbackQuery(ctx: client.Context, update: types.UpdateInlineBotCallbackQuery, opts: CallbackAnswerOptions) !void {
    try ctx.exec(functions.messages.SetBotCallbackAnswer{
        .alert = if (opts.alert) .some({}) else .none,
        .query_id = update.query_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .url = if (opts.url) |u| .some(u) else .none,
        .cache_time = opts.cache_time,
    });
}

pub fn answerInlineQuery(ctx: client.Context, update: types.UpdateBotInlineQuery, results: []const types.InputBotInlineResult, opts: InlineQueryOptions) !void {
    try ctx.exec(functions.messages.SetInlineBotResults{
        .gallery = if (opts.is_gallery) .some({}) else .none,
        .private = if (opts.is_private) .some({}) else .none,
        .query_id = update.query_id,
        .results = results,
        .cache_time = opts.cache_time,
        .next_offset = if (opts.next_offset) |o| .some(o) else .none,
    });
}

pub fn addReaction(ctx: client.Context, peer: types.InputPeer, msg_id: i32, emoticon: []const u8) !void {
    var reactions = [_]types.Reaction{.{ .ReactionEmoji = .{ .emoticon = emoticon } }};
    try ctx.exec(functions.messages.SendReaction{
        .peer = peer,
        .msg_id = msg_id,
        .reaction = .some(&reactions),
    });
}

pub fn removeReaction(ctx: client.Context, peer: types.InputPeer, msg_id: i32) !void {
    var reactions = [_]types.Reaction{};
    try ctx.exec(functions.messages.SendReaction{
        .peer = peer,
        .msg_id = msg_id,
        .reaction = .some(&reactions),
    });
}

pub fn getUsers(ctx: client.Context, ids: []const types.InputUser) ![]const types.User {
    return ctx.call(functions.users.GetUsers{ .id = ids });
}

pub fn getChats(ctx: client.Context, ids: []const i64) ![]const types.Chat {
    const res = try ctx.call(functions.messages.GetChats{ .id = ids });
    return switch (res) {
        .MessagesChats => |r| r.chats,
        .MessagesChatsSlice => |r| r.chats,
    };
}

pub fn getChannels(ctx: client.Context, ids: []const types.InputChannel) ![]const types.Chat {
    const res = try ctx.call(functions.channels.GetChannels{ .id = ids });
    return switch (res) {
        .MessagesChats => |r| r.chats,
        .MessagesChatsSlice => |r| r.chats,
    };
}

pub fn Cmd(comptime U: type) type {
    return struct {
        pattern: []const u8,
        is_prefix: bool = false,
        handler: *const fn (client.Context, U) anyerror!void,

        const Self = @This();

        pub fn exact(comptime pattern: []const u8, comptime h: fn (client.Context, U) anyerror!void) Self {
            return .{ .pattern = pattern, .handler = h };
        }

        pub fn prefix(comptime pattern: []const u8, comptime h: fn (client.Context, U) anyerror!void) Self {
            return .{ .pattern = pattern, .is_prefix = true, .handler = h };
        }
    };
}

pub fn route(ctx: client.Context, update: anytype, text: []const u8, comptime routes: anytype) !bool {
    inline for (routes) |r| {
        const matched = if (r.is_prefix)
            std.mem.startsWith(u8, text, r.pattern)
        else
            std.mem.eql(u8, text, r.pattern);
        if (matched) {
            try r.handler(ctx, update);
            return true;
        }
    }
    return false;
}

pub fn peerFromMessage(entities: client.Entities, msg: types.Message_) ?types.InputPeer {
    return switch (msg.peer_id) {
        .PeerUser => |p| .{ .InputPeerUser = .{
            .user_id = p.user_id,
            .access_hash = entities.accessHash(p.user_id) orelse return null,
        } },
        .PeerChat => |p| .{ .InputPeerChat = .{ .chat_id = p.chat_id } },
        .PeerChannel => |p| .{ .InputPeerChannel = .{
            .channel_id = p.channel_id,
            .access_hash = entities.channelAccessHash(p.channel_id) orelse return null,
        } },
    };
}

pub fn peerFromCallbackQuery(entities: client.Entities, update: types.UpdateBotCallbackQuery) ?types.InputPeer {
    return switch (update.peer) {
        .PeerUser => |p| .{ .InputPeerUser = .{
            .user_id = p.user_id,
            .access_hash = entities.accessHash(p.user_id) orelse return null,
        } },
        .PeerChat => |p| .{ .InputPeerChat = .{ .chat_id = p.chat_id } },
        .PeerChannel => |p| .{ .InputPeerChannel = .{
            .channel_id = p.channel_id,
            .access_hash = entities.channelAccessHash(p.channel_id) orelse return null,
        } },
    };
}
