# tz

Work in progress — rough edges, missing features, API may change.

Telegram MTProto API client in Zig, requires Zig 0.16.

Echo bot binary: ~518 KB (`ReleaseSmall`) / ~780KB (`ReleaseSmall`,statically linked)

## Features

- MTProto 2.0 authentication key exchange
- Encrypted session with server salt auto-renewal
- TCP and WebSocket transports
- TL schema codegen — types and functions generated from `schema/*.tl` at build time
- Comptime handler dispatch — register handlers per update type, zero runtime overhead
- `FileStorage` / `MemoryStorage` for session persistence
- Bot and user account auth
- File upload (`tz.upload`) with automatic cross-DC routing

## Usage

**Handle an update.** `UpdateNewMessage.message` is a union — switch to get the concrete `Message`:

```zig
fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0) return;
    try tz.helpers.reply(ctx, update, msg.message, .{});
}
```

**Call any TL function directly** via `ctx.call`:

```zig
// read: inspect the returned value
var id_input = [_]tg.InputUser{.{ .InputUserSelf = .{} }};
const users = try ctx.call(f.users.GetUsers{ .id = &id_input });
defer ctx.allocator.free(users);

// mutate: discard the response
var ids = [_]i32{msg.id};
_ = try ctx.call(f.messages.DeleteMessages{ .id = &ids });
```

**Register handlers** — multiple handlers on the same type are zero-overhead (comptime dispatch):

```zig
const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onCommand),
    tz.handler(tg.UpdateNewMessage, onEcho),
};
```

**Boot the client:**

```zig
var storage = tz.FileStorage.init("bot.session");

const client = try tz.Client(handlers).init(allocator, .{
    .api_id    = api_id,
    .api_hash  = api_hash,
    .bot_token = bot_token,
    .storage   = storage.storage(),
});
defer client.deinit();

try client.run(io);
```

See [examples/](examples/) for complete runnable examples.

## Dependency

```sh
zig fetch --save https://github.com/ocfox/tz/archive/refs/tags/v0.0.2.tar.gz
```

Then in `build.zig`:

```zig
const tz = b.dependency("tz", .{});
exe.root_module.addImport("tz", tz.module("tz"));
```
