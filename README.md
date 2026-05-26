# tz

telegram mtproto client in zig 0.16. wip.

echo bot: ~700kb statically linked (`ReleaseSmall`).

implements: mtproto 2.0, tcp transport (abridged/intermediate/padded), tl codegen from schema, comptime handler dispatch, bot/user auth, file upload/download, session persistence.

## usage

```zig
fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) { .Message => |m| m, else => return };
    try tz.helpers.reply(ctx, update, msg.message, .{});
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onMessage),
};

// boot
var storage = tz.storage.FileStorage.init("bot.session");
const client = try tz.Client(handlers).init(allocator, .{
    .api_id    = api_id,
    .api_hash  = api_hash,
    .bot_token = bot_token,
    .storage   = storage.storage(),
});
defer client.deinit();
try client.run(io);
```

call any tl function:

```zig
var id_input = [_]tg.InputUser{.{ .InputUserSelf = .{} }};
const users = try ctx.call(f.users.GetUsers{ .id = &id_input });
defer ctx.allocator.free(users);
```

helpers:

```zig
try tz.helpers.media.sendPhoto(ctx, update, jpeg_bytes, .{});
try tz.helpers.media.sendDocument(ctx, update, pdf_bytes, "application/pdf", .{ .caption = "report" });
try tz.helpers.media.sendAudio(ctx, update, mp3_bytes, "audio/mpeg", .{ .title = "Track", .performer = "Artist" });
try tz.helpers.media.sendVideo(ctx, update, mp4_bytes, "video/mp4", .{});
try tz.helpers.media.sendVoice(ctx, update, ogg_bytes, .{});
try tz.helpers.forwardMessages(ctx, from_peer, to_peer, &[_]i32{msg.id});
try tz.helpers.pinMessage(ctx, peer, msg.id, .{});
try tz.helpers.addReaction(ctx, peer, msg.id, "❤");

var ft = tz.helpers.fmt.FormattedText.init(allocator);
defer ft.deinit();
try ft.bold("hello"); try ft.plain(" world");
try tz.helpers.reply(ctx, update, ft.text.items, .{ .entities = ft.entities.items });

const bytes = try tz.helpers.download(ctx, tz.helpers.photoLocation(photo).?);
defer allocator.free(bytes);
```

command routing:

```zig
const R = tz.helpers.Cmd(tg.UpdateNewMessage);
if (try tz.helpers.route(ctx, update, msg.message, &.{
    R.exact("/start", onStart),
    R.prefix("/echo ", onEcho),
})) return;
```

see [examples/](examples/).
