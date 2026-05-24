# tz

Work in progress — rough edges, missing features, API may change.

Telegram MTProto API client in Zig, requires Zig 0.16.

Echo bot binary: ~518 KB (`ReleaseSmall`).

## Features

- MTProto 2.0 authentication key exchange
- Encrypted session with server salt auto-renewal
- TCP and WebSocket transports
- TL schema codegen — types and functions generated from `schema/*.tl` at build time
- Comptime handler dispatch — register handlers per update type, zero runtime overhead
- `FileStorage` / `MemoryStorage` for session persistence
- Bot token auth

## Usage

```zig
const std = @import("std");
const tz = @import("tz");
const tg = tz.types;

fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    // UpdateNewMessage.message is a union — switch to get the concrete Message.
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0) return;
    try tz.helpers.reply(ctx, update, msg.message, .{});
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onMessage),
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var storage = tz.FileStorage.init("bot.session");

    const client = try tz.Client(handlers).init(allocator, .{
        .api_id    = api_id,     // https://core.telegram.org/api/obtaining_api_id
        .api_hash  = api_hash,
        .bot_token = bot_token,
        .storage   = storage.storage(),
    });
    defer client.deinit();

    try client.run(io);
}
```

See [examples](examples/) for runnable examples.

## Dependency

```sh
zig fetch --save https://github.com/ocfox/tz
```

Then in `build.zig`:

```zig
const tz = b.dependency("tz", .{});
exe.root_module.addImport("tz", tz.module("tz"));
```
