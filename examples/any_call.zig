//! any_call — demonstrates direct ctx.call() usage without helpers.
//!
//! Two handlers on the same update type, split by functional boundary:
//!   onCommand  — /whoami (fetch own user) and /delete (delete command message)
//!   onEcho     — everything else: echo with a quote reply
//!
//! UpdateNewMessage.message is a union (Message | MessageService | MessageEmpty),
//! so every handler must switch on it — there is no shortcut.
//!
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> zig build any-call

const std = @import("std");
const tz = @import("tz");
const tg = tz.types;
const f = tz.functions;

fn onCommand(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0 or msg.message[0] != '/') return;

    const peer = tz.helpers.peerFromMessage(ctx.entities, msg) orelse return;

    if (std.mem.eql(u8, msg.message, "/whoami")) {
        var id_input = [_]tg.InputUser{.{ .InputUserSelf = .{} }};
        const users = try ctx.call(f.users.GetUsers{ .id = &id_input });
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
            .peer = peer,
            .message = text,
            .random_id = tz.nextRandomId(),
        });
    } else if (std.mem.eql(u8, msg.message, "/delete")) {
        var ids = [_]i32{msg.id};
        _ = try ctx.call(f.messages.DeleteMessages{
            .id = &ids,
        });
    }
}

fn onEcho(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0 or msg.message[0] == '/') return;

    const peer = tz.helpers.peerFromMessage(ctx.entities, msg) orelse return;
    _ = try ctx.call(f.messages.SendMessage{
        .peer = peer,
        .message = msg.message,
        .reply_to = .some(.{ .InputReplyToMessage = .{
            .reply_to_msg_id = msg.id,
        } }),
        .random_id = tz.nextRandomId(),
    });
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onCommand),
    tz.handler(tg.UpdateNewMessage, onEcho),
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
