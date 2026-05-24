const types = @import("types");
const functions = @import("functions");
const client_mod = @import("client.zig");

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
