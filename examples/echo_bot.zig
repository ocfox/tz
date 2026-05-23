const std = @import("std");
const tz = @import("tz");
const tg = tz.types;

fn onNewMessage(client: *tz.Client, io: std.Io, entities: tz.Entities, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.out.value != null) return;
    if (msg.message.len == 0) return;

    const sender = tz.message.Sender.init(client);
    if (sender.reply(entities, update)) |req| {
        try req.text(io, msg.message);
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const api_id_str = std.c.getenv("TZ_API_ID") orelse usage();
    const api_id = try std.fmt.parseInt(i32, std.mem.span(api_id_str), 10);
    const api_hash = std.mem.span(std.c.getenv("TZ_API_HASH") orelse usage());
    const bot_token = std.mem.span(std.c.getenv("TZ_BOT_TOKEN") orelse usage());

    tz.message.initRandomCounter();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dispatcher = tz.Dispatcher.init(allocator);
    defer dispatcher.deinit();
    try dispatcher.on(tg.UpdateNewMessage, onNewMessage);

    var file_storage = tz.FileStorage.init("echo_bot.session");

    const client = try tz.Client.init(allocator, .{
        .api_id = api_id,
        .api_hash = api_hash,
        .bot_token = bot_token,
        .storage = file_storage.storage(),
        .handler = dispatcher.handler(),
    });
    defer client.deinit();

    dispatcher.bindClient(client);

    try client.run(io);
}

fn usage() noreturn {
    std.debug.print("usage: TZ_API_ID=<id> TZ_API_HASH=<hash> TZ_BOT_TOKEN=<token> ./echo_bot\n", .{});
    std.process.exit(1);
}
