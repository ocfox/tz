# tz

**WIP — rough edges, missing features, API may change.**

Telegram MTProto API client in Zig, Requires Zig 0.16.

Echo bot binary: ~518 KB (`ReleaseSmall`, statically linked).

## Features

- MTProto 2.0 authentication key exchange
- Encrypted session with server salt auto-renewal
- TCP and WebSocket transports
- TL schema codegen — types and functions generated from `schema/*.tl` at build time
- Typed update dispatcher — register handlers per update type, zero serialization overhead
- `FileStorage` / `MemoryStorage` for session persistence
- Bot token auth

## Usage

```zig
const std = @import("std");
const tz = @import("tz");
const tg = tz.types;

fn onMessage(client: *tz.Client, io: std.Io, entities: tz.Entities, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.out.value != null) return;

    const sender = tz.message.Sender.init(client);
    if (sender.reply(entities, update)) |req| try req.text(io, msg.message);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dispatcher = tz.Dispatcher.init(allocator);
    defer dispatcher.deinit();
    try dispatcher.on(tg.UpdateNewMessage, onMessage);

    var storage = tz.FileStorage.init("bot.session");

    const client = try tz.Client.init(allocator, .{
        .api_id    = api_id,     // https://core.telegram.org/api/obtaining_api_id
        .api_hash  = api_hash,
        .bot_token = bot_token,
        .storage   = storage.storage(),
        .handler   = dispatcher.handler(),
    });
    defer client.deinit();

    dispatcher.bindClient(client);
    try client.run(io);
}
```

See [examples/echo_bot.zig](examples/echo_bot.zig) for a runnable example.

## Dependency

```sh
zig fetch --save https://github.com/ocfox/tz
```

Then in `build.zig`:

```zig
const tz = b.dependency("tz", .{});
exe.root_module.addImport("tz", tz.module("tz"));
```
