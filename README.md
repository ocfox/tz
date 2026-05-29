# tz

telegram mtproto client in zig 0.16. zero dependency. wip.

echo bot: ~700kb statically linked (`ReleaseSmall`).

implements: mtproto 2.0, tcp transport (abridged/intermediate/padded), tl codegen from schema, comptime handler dispatch, bot/user auth, file upload/download, session persistence, reliable updates (pts/qts gap detection with `getDifference` recovery, persisted across restarts).

## usage

```zig
const h = tz.helpers;

fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) { .Message => |m| m, else => return };
    try h.reply(ctx, update, msg.message, .{});
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onMessage),
};

var storage = tz.Storage.File.init("bot.session");
const client = try tz.Client(handlers).init(allocator, .{
    .api_id    = api_id,
    .api_hash  = api_hash,
    .bot_token = bot_token,
    .storage   = storage.storage(),
});
defer client.deinit();
try client.run(io);
```

call any tl function directly. `call` returns a `Response(T)` that owns the decoded
value and all its nested allocations — free the whole tree with `deinit()`. Use
`exec` instead when you don't need the response (it allocates nothing for the reply):

```zig
var id_input = [_]tg.InputUser{.{ .InputUserSelf = .{} }};
const resp = try ctx.call(f.users.GetUsers{ .id = &id_input });
defer resp.deinit();
const users = resp.value;

try ctx.exec(f.messages.SendMessage{ .peer = peer, .message = "hi" });
```

helpers:

```zig
try h.media.sendPhoto(ctx, update, jpeg_bytes, .{});
try h.media.sendDocument(ctx, update, pdf_bytes, "application/pdf", .{ .caption = "report" });
try h.media.sendAudio(ctx, update, mp3_bytes, "audio/mpeg", .{ .title = "Track", .performer = "Artist" });
try h.media.sendVideo(ctx, update, mp4_bytes, "video/mp4", .{});
try h.media.sendVoice(ctx, update, ogg_bytes, .{});
try h.forwardMessages(ctx, from_peer, to_peer, &[_]i32{msg.id});
try h.pinMessage(ctx, peer, msg.id, .{});
try h.addReaction(ctx, peer, msg.id, "❤");

var ft = h.FormattedText.init(allocator);
defer ft.deinit();
try ft.bold("hello"); try ft.plain(" world");
try h.reply(ctx, update, ft.text.items, .{ .entities = ft.entities.items });

const bytes = try h.download(ctx, h.photoLocation(photo).?);
defer allocator.free(bytes);
```

command routing:

```zig
const R = h.Cmd(tg.UpdateNewMessage);
if (try h.route(ctx, update, msg.message, &.{
    R.exact("/start", onStart),
    R.prefix("/echo ", onEcho),
})) return;
```

see [examples/](examples/).
