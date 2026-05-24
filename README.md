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
- File upload and download (`tz.helpers.upload` / `tz.helpers.download`) with automatic cross-DC routing
- `tz.helpers` — send photo/document/audio/video/voice/album, forward, pin, react, edit, inline keyboards, formatted text

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

**`tz.helpers` shortcuts** — common operations without manual TL construction:

```zig
// Send media
try tz.helpers.sendPhoto(ctx, update, jpeg_bytes, .{});
try tz.helpers.sendDocument(ctx, update, pdf_bytes, "application/pdf", .{ .caption = "report" });
try tz.helpers.sendAudio(ctx, update, mp3_bytes, "audio/mpeg", .{ .title = "Track", .performer = "Artist" });
try tz.helpers.sendVideo(ctx, update, mp4_bytes, "video/mp4", .{});
try tz.helpers.sendVoice(ctx, update, ogg_bytes, .{});

// Album (multi-media)
const items = &[_]tz.helpers.AlbumItem{
    .{ .data = img1, .caption = "first" },
    .{ .data = img2 },
};
try tz.helpers.sendAlbum(ctx, update, items, .{});

// Forward / pin
try tz.helpers.forwardMessages(ctx, from_peer, to_peer, &[_]i32{msg.id});
try tz.helpers.pinMessage(ctx, peer, msg.id, .{});

// React
try tz.helpers.addReaction(ctx, peer, msg.id, "👍");
try tz.helpers.removeReaction(ctx, peer, msg.id);

// Formatted text with MessageEntity
var ft = tz.helpers.FormattedText.init(allocator);
defer ft.deinit();
try ft.bold("Warning");
try ft.plain(": file not found");
try tz.helpers.reply(ctx, update, ft.text.items, .{ .entities = ft.entities.items });

// Download
const location = tz.helpers.photoLocation(photo) orelse return;
const bytes = try tz.helpers.download(ctx, location);
defer allocator.free(bytes);
```

See [examples/](examples/) for complete runnable examples.

## Dependency

```sh
zig fetch --save https://github.com/ocfox/tz/archive/master.tar.gz
```

Then in `build.zig`:

```zig
const tz = b.dependency("tz", .{});
exe.root_module.addImport("tz", tz.module("tz"));
```
