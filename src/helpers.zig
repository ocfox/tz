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
