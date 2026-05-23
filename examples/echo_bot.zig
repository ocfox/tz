//! echo_bot — echoes every message it receives.
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> zig build echo-bot

const std = @import("std");
const tz = @import("tz");
const tg = tz.types;

fn onNewMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    // Ignore empty messages.
    if (msg.message.len == 0) return;
    try ctx.reply(update, msg.message);
}

// Compile-time handler list. No runtime hashmap, no dispatcher to .init() or .bind().
const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onNewMessage),
};

pub fn main() !void {
    // A debug allocator catches leaks and double-frees when the program exits.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // std.Io.Threaded gives us an IO runtime backed by a thread pool.
    // All network IO and timers go through this.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Session is persisted to disk so the bot can reconnect without re-doing DH key exchange.
    var file_storage = tz.FileStorage.init("echo_bot.session");

    // Credentials are read from environment and wired directly into Client.
    const client = try tz.Client(handlers).init(allocator, .{
        .api_id = try std.fmt.parseInt(i32,
            std.mem.span(std.c.getenv("TZ_API_ID") orelse usage()), 10),
        .api_hash = std.mem.span(std.c.getenv("TZ_API_HASH") orelse usage()),
        .bot_token = std.mem.span(std.c.getenv("TZ_BOT_TOKEN") orelse usage()),
        .storage = file_storage.storage(),
    });
    defer client.deinit();

    // run() blocks until close() is called. Reconnects automatically on disconnect.
    try client.run(io);
}

fn usage() noreturn {
    std.debug.print("usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> ./echo_bot\n", .{});
    std.process.exit(1);
}
