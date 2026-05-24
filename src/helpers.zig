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
        .peer = peer,
        .message = text,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
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
        .peer = peer,
        .media = .{ .InputMediaUploadedPhoto = .{ .file = input_file } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
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
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

pub const AudioOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
    duration: i32 = 0,
    title: ?[]const u8 = null,
    performer: ?[]const u8 = null,
    name: []const u8 = "audio",
};

/// Upload raw bytes as an audio file and send it to the same chat as `update`.
pub fn sendAudio(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: AudioOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = opts.name });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeAudio = .{
        .duration = opts.duration,
        .title = if (opts.title) |t| .some(t) else .none,
        .performer = if (opts.performer) |p| .some(p) else .none,
    } }};
    _ = try ctx.call(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

pub const VideoOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
    duration: f64 = 0,
    w: i32 = 0,
    h: i32 = 0,
    supports_streaming: bool = true,
    name: []const u8 = "video",
};

/// Upload raw bytes as a video file and send it to the same chat as `update`.
pub fn sendVideo(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: VideoOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = opts.name });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeVideo = .{
        .supports_streaming = if (opts.supports_streaming) .some({}) else .none,
        .duration = opts.duration,
        .w = opts.w,
        .h = opts.h,
    } }};
    _ = try ctx.call(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .random_id = client_mod.nextRandomId(),
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

pub const AlbumItem = struct {
    data: []const u8,
    caption: []const u8 = "",
    name: []const u8 = "photo.jpg",
};

/// Upload and send multiple photos as an album (SendMultiMedia).
pub fn sendAlbum(ctx: Context, update: types.UpdateNewMessage, items: []const AlbumItem, opts: ReplyOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;

    const media_items = try ctx.allocator.alloc(types.InputSingleMedia, items.len);
    defer ctx.allocator.free(media_items);
    const checksums = try ctx.allocator.alloc(?[]const u8, items.len);
    defer ctx.allocator.free(checksums);
    defer for (checksums) |c| if (c) |s| ctx.allocator.free(s);
    @memset(checksums, null);

    for (items, 0..) |item, i| {
        const input_file = try upload_mod.upload(ctx, item.data, .{ .name = item.name });
        if (input_file == .InputFile) checksums[i] = input_file.InputFile.md5_checksum;
        media_items[i] = .{
            .media = .{ .InputMediaUploadedPhoto = .{ .file = input_file } },
            .random_id = client_mod.nextRandomId(),
            .message = item.caption,
        };
    }

    _ = try ctx.call(functions.messages.SendMultiMedia{
        .peer = peer,
        .multi_media = media_items,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{
            .reply_to_msg_id = id,
        } }) else .none,
    });
}

/// Forward messages from one peer to another.
pub fn forwardMessages(ctx: Context, from_peer: types.InputPeer, to_peer: types.InputPeer, ids: []i32) !void {
    const random_ids = try ctx.allocator.alloc(i64, ids.len);
    defer ctx.allocator.free(random_ids);
    for (random_ids) |*r| r.* = client_mod.nextRandomId();
    _ = try ctx.call(functions.messages.ForwardMessages{
        .from_peer = from_peer,
        .id = ids,
        .random_id = random_ids,
        .to_peer = to_peer,
    });
}

pub const PinOptions = struct {
    silent: bool = false,
    unpin: bool = false,
    pm_oneside: bool = false,
};

/// Pin or unpin a message by peer + message id.
pub fn pinMessage(ctx: Context, peer: types.InputPeer, msg_id: i32, opts: PinOptions) !void {
    _ = try ctx.call(functions.messages.UpdatePinnedMessage{
        .peer = peer,
        .id = msg_id,
        .silent = if (opts.silent) .some({}) else .none,
        .unpin = if (opts.unpin) .some({}) else .none,
        .pm_oneside = if (opts.pm_oneside) .some({}) else .none,
    });
}

pub fn callbackButton(text: []const u8, data: []const u8) types.KeyboardButton {
    return .{ .KeyboardButtonCallback = .{ .text = text, .data = data } };
}

pub fn urlButton(text: []const u8, url: []const u8) types.KeyboardButton {
    return .{ .KeyboardButtonUrl = .{ .text = text, .url = url } };
}

pub fn inlineRow(buttons: []types.KeyboardButton) types.KeyboardButtonRow {
    return .{ .buttons = buttons };
}

pub fn inlineKeyboard(rows: []types.KeyboardButtonRow) types.ReplyMarkup {
    return .{ .ReplyInlineMarkup = .{ .rows = rows } };
}

pub const EditOptions = struct {
    text: ?[]const u8 = null,
    reply_markup: ?types.ReplyMarkup = null,
};

/// Edit a message by peer + message id.
/// At least one of text or reply_markup must be set.
pub fn editMessage(ctx: Context, peer: types.InputPeer, msg_id: i32, opts: EditOptions) !void {
    _ = try ctx.call(functions.messages.EditMessage{
        .peer = peer,
        .id = msg_id,
        .message = if (opts.text) |t| .some(t) else .none,
        .reply_markup = if (opts.reply_markup) |m| .some(m) else .none,
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
        .gallery = if (opts.is_gallery) .some({}) else .none,
        .private = if (opts.is_private) .some({}) else .none,
        .query_id = update.query_id,
        .results = @constCast(results),
        .cache_time = opts.cache_time,
        .next_offset = if (opts.next_offset) |o| .some(o) else .none,
    });
}

pub fn peerFromCallbackQuery(entities: Entities, update: types.UpdateBotCallbackQuery) ?types.InputPeer {
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
