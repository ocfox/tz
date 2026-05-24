//! any_call — demonstrates direct ctx.call() usage without helpers.
//!
//! Commands:
//!   /whoami   — fetch own user via users.GetUsers and reply with name + id
//!   /delete   — delete the command message itself
//!   anything else — echo with a quote reply, peer constructed manually
//!
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> zig build any-call

const std = @import("std");
const tz = @import("tz");
const tg = tz.types;
const f = tz.functions;

fn onNewMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0) return;

    // Resolve the reply target peer from ctx.entities manually.
    // helpers.peerFromMessage does the same thing — shown here for clarity.
    const peer: tg.InputPeer = switch (msg.peer_id) {
        .PeerUser => |p| .{ .InputPeerUser = .{
            .user_id = p.user_id,
            .access_hash = ctx.entities.accessHash(p.user_id) orelse return,
        } },
        .PeerChat => |p| .{ .InputPeerChat = .{ .chat_id = p.chat_id } },
        .PeerChannel => |p| .{ .InputPeerChannel = .{
            .channel_id = p.channel_id,
            .access_hash = ctx.entities.channelAccessHash(p.channel_id) orelse return,
        } },
    };

    if (std.mem.eql(u8, msg.message, "/whoami")) {
        // Case 1: call a function that returns data, build a reply from it.
        var self_input = [_]tg.InputUser{.{ .InputUserSelf = .{} }};
        const users = try ctx.call(f.users.GetUsers{ .id = &self_input });
        defer ctx.allocator.free(users);

        const user = switch (users[0]) {
            .User => |u| u,
            else => return,
        };

        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "id={} name={s}", .{
            user.id,
            user.first_name.value orelse "(none)",
        });

        _ = try ctx.call(f.messages.SendMessage{
            .flags = .{},
            .peer = peer,
            .message = text,
            .random_id = tz.nextRandomId(),
        });
    } else if (std.mem.eql(u8, msg.message, "/delete")) {
        // Case 2: call a function that mutates state, discard the response.
        var ids = [_]i32{msg.id};
        _ = try ctx.call(f.messages.DeleteMessages{
            .flags = .{},
            .id = &ids,
        });
    } else {
        // Case 3: echo with a quote reply — reply_to constructed explicitly.
        _ = try ctx.call(f.messages.SendMessage{
            .flags = .{},
            .peer = peer,
            .message = msg.message,
            .reply_to = .some(.{ .InputReplyToMessage = .{
                .flags = .{},
                .reply_to_msg_id = msg.id,
            } }),
            .random_id = tz.nextRandomId(),
        });
    }
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onNewMessage),
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var file_storage = tz.FileStorage.init("any_call.session");

    const client = try tz.Client(handlers).init(allocator, .{
        .api_id = try std.fmt.parseInt(i32,
            std.mem.span(std.c.getenv("TZ_API_ID") orelse usage()), 10),
        .api_hash = std.mem.span(std.c.getenv("TZ_API_HASH") orelse usage()),
        .bot_token = std.mem.span(std.c.getenv("TZ_BOT_TOKEN") orelse usage()),
        .storage = file_storage.storage(),
    });
    defer client.deinit();

    try client.run(io);
}

fn usage() noreturn {
    std.log.err("usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> ./any_call", .{});
    std.process.exit(1);
}
