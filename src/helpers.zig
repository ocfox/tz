const types = @import("types");
const functions = @import("functions");
const client_mod = @import("client.zig");
const upload_mod = @import("upload.zig");

pub const Context = client_mod.Context;
pub const Entities = client_mod.Entities;

pub const ReplyOptions = struct {
    reply_to: ?i32 = null,
};

/// Reply to a message in a private chat, group, or channel.
/// Peer and access_hash are resolved automatically from ctx.entities.
/// Returns without sending if the peer type is unrecognised or access_hash is missing.
pub fn reply(
    ctx: Context,
    update: types.UpdateNewMessage,
    text: []const u8,
    opts: ReplyOptions,
) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    _ = try ctx.call(functions.messages.SendMessage{
        .flags = .{},
        .peer = peer,
        .message = text,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .flags = .{},
            .reply_to_msg_id = id,
        } }) else .none,
        .random_id = client_mod.nextRandomId(),
    });
}

pub const SendMediaOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
};

/// Upload raw bytes as a photo and send it to the same chat as `update`.
pub fn sendPhoto(ctx: Context, update: types.UpdateNewMessage, data: []const u8, opts: SendMediaOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = "photo.jpg" });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig => {},
    };
    _ = try ctx.call(functions.messages.SendMedia{
        .flags = .{},
        .peer = peer,
        .media = .{ .InputMediaUploadedPhoto = .{ .flags = .{}, .file = input_file } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .flags = .{},
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

/// Upload raw bytes as a document and send it to the same chat as `update`.
pub fn sendDocument(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: SendMediaOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = "file" });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeFilename = .{ .file_name = "file" } }};
    _ = try ctx.call(functions.messages.SendMedia{
        .flags = .{},
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .flags = .{},
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .flags = .{},
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

pub const CallbackAnswerOptions = struct {
    text: ?[]const u8 = null,
    alert: bool = false,
    url: ?[]const u8 = null,
    cache_time: i32 = 0,
};

/// Answer a button callback query (UpdateBotCallbackQuery).
pub fn answerCallbackQuery(ctx: Context, update: types.UpdateBotCallbackQuery, opts: CallbackAnswerOptions) !void {
    _ = try ctx.call(functions.messages.SetBotCallbackAnswer{
        .flags = .{},
        .alert = if (opts.alert) .some({}) else .none,
        .query_id = update.query_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .url = if (opts.url) |u| .some(u) else .none,
        .cache_time = opts.cache_time,
    });
}

/// Answer a callback query from an inline message (UpdateInlineBotCallbackQuery).
pub fn answerInlineCallbackQuery(ctx: Context, update: types.UpdateInlineBotCallbackQuery, opts: CallbackAnswerOptions) !void {
    _ = try ctx.call(functions.messages.SetBotCallbackAnswer{
        .flags = .{},
        .alert = if (opts.alert) .some({}) else .none,
        .query_id = update.query_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .url = if (opts.url) |u| .some(u) else .none,
        .cache_time = opts.cache_time,
    });
}

pub const InlineQueryOptions = struct {
    cache_time: i32 = 300,
    is_gallery: bool = false,
    is_private: bool = false,
    next_offset: ?[]const u8 = null,
};

/// Answer an inline query (UpdateBotInlineQuery). Results are constructed by the caller.
pub fn answerInlineQuery(ctx: Context, update: types.UpdateBotInlineQuery, results: []const types.InputBotInlineResult, opts: InlineQueryOptions) !void {
    _ = try ctx.call(functions.messages.SetInlineBotResults{
        .flags = .{},
        .gallery = if (opts.is_gallery) .some({}) else .none,
        .private = if (opts.is_private) .some({}) else .none,
        .query_id = update.query_id,
        .results = @constCast(results),
        .cache_time = opts.cache_time,
        .next_offset = if (opts.next_offset) |o| .some(o) else .none,
    });
}

pub fn peerFromMessage(entities: Entities, msg: types.Message_) ?types.InputPeer {
    return switch (msg.peer_id) {
        .PeerUser => |p| .{ .InputPeerUser = .{
            .user_id = p.user_id,
            .access_hash = entities.accessHash(p.user_id) orelse return null,
        } },
        .PeerChat => |p| .{ .InputPeerChat = .{
            .chat_id = p.chat_id,
        } },
        .PeerChannel => |p| .{ .InputPeerChannel = .{
            .channel_id = p.channel_id,
            .access_hash = entities.channelAccessHash(p.channel_id) orelse return null,
        } },
    };
}
