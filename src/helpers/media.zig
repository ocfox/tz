const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const client_mod = @import("../client.zig");
const upload_mod = @import("../upload.zig");

const Context = client_mod.Context;

pub const SendMediaOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
};

pub const AudioOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
    duration: i32 = 0,
    title: ?[]const u8 = null,
    performer: ?[]const u8 = null,
    name: []const u8 = "audio",
};

pub const VideoOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
    duration: f64 = 0,
    w: i32 = 0,
    h: i32 = 0,
    supports_streaming: bool = true,
    name: []const u8 = "video",
};

pub const VoiceOptions = struct {
    caption: []const u8 = "",
    reply_to: ?i32 = null,
    duration: i32 = 0,
    name: []const u8 = "voice.ogg",
};

pub const AlbumItemKind = enum { photo, document };

pub const AlbumItem = struct {
    data: []const u8,
    caption: []const u8 = "",
    name: []const u8 = "file",
    kind: AlbumItemKind = .photo,
    mime_type: []const u8 = "application/octet-stream",
};

pub const AlbumOptions = struct {
    reply_to: ?i32 = null,
};

fn peerFromMessage(entities: client_mod.Entities, msg: types.Message_) ?types.InputPeer {
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

pub fn sendPhoto(ctx: Context, update: types.UpdateNewMessage, data: []const u8, opts: SendMediaOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = "photo.jpg" });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig, .InputFileStoryDocument => {},
    };
    try ctx.exec(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedPhoto = .{ .file = input_file } },
        .message = opts.caption,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn sendDocument(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: SendMediaOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = "file" });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig, .InputFileStoryDocument => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeFilename = .{ .file_name = "file" } }};
    try ctx.exec(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn sendAudio(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: AudioOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = opts.name });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig, .InputFileStoryDocument => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeAudio = .{
        .duration = opts.duration,
        .title = if (opts.title) |t| .some(t) else .none,
        .performer = if (opts.performer) |p| .some(p) else .none,
    } }};
    try ctx.exec(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn sendVideo(ctx: Context, update: types.UpdateNewMessage, data: []const u8, mime_type: []const u8, opts: VideoOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = opts.name });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig, .InputFileStoryDocument => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeVideo = .{
        .supports_streaming = if (opts.supports_streaming) .some({}) else .none,
        .duration = opts.duration,
        .w = opts.w,
        .h = opts.h,
    } }};
    try ctx.exec(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = mime_type,
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn sendVoice(ctx: Context, update: types.UpdateNewMessage, data: []const u8, opts: VoiceOptions) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    const peer = peerFromMessage(ctx.entities, msg) orelse return;
    const input_file = try upload_mod.upload(ctx, data, .{ .name = opts.name });
    defer switch (input_file) {
        .InputFile => |f| ctx.allocator.free(f.md5_checksum),
        .InputFileBig, .InputFileStoryDocument => {},
    };
    var attrs = [_]types.DocumentAttribute{.{ .DocumentAttributeAudio = .{
        .voice = .some({}),
        .duration = opts.duration,
    } }};
    try ctx.exec(functions.messages.SendMedia{
        .peer = peer,
        .media = .{ .InputMediaUploadedDocument = .{
            .file = input_file,
            .mime_type = "audio/ogg",
            .attributes = &attrs,
        } },
        .message = opts.caption,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}

pub fn sendAlbum(ctx: Context, update: types.UpdateNewMessage, items: []const AlbumItem, opts: AlbumOptions) !void {
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
    const attrs_buf = try ctx.allocator.alloc(types.DocumentAttribute, items.len);
    defer ctx.allocator.free(attrs_buf);

    for (items, 0..) |item, i| {
        const input_file = try upload_mod.upload(ctx, item.data, .{ .name = item.name });
        if (input_file == .InputFile) checksums[i] = input_file.InputFile.md5_checksum;
        const media: types.InputMedia = switch (item.kind) {
            .photo => .{ .InputMediaUploadedPhoto = .{ .file = input_file } },
            .document => blk: {
                attrs_buf[i] = .{ .DocumentAttributeFilename = .{ .file_name = item.name } };
                break :blk .{ .InputMediaUploadedDocument = .{
                    .file = input_file,
                    .mime_type = item.mime_type,
                    .attributes = attrs_buf[i .. i + 1],
                } };
            },
        };
        var rand_id: i64 = undefined;
        ctx.io.random(std.mem.asBytes(&rand_id));
        media_items[i] = .{ .media = media, .message = item.caption, .random_id = rand_id };
    }

    try ctx.exec(functions.messages.SendMultiMedia{
        .peer = peer,
        .multi_media = media_items,
        .reply_to = if (opts.reply_to) |id| .some(.{ .InputReplyToMessage = .{ .reply_to_msg_id = id } }) else .none,
    });
}
