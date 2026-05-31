# tz

telegram mtproto client in zig 0.16. zero dependency. wip.

echo bot: ~700kb statically linked (`ReleaseSmall`).

- tcp transport (abridged / intermediate / padded)
- tl codegen from schema at build time
- comptime handler dispatch — zero-overhead update routing
- bot and user auth
- file upload / download — streaming, CDN-transparent
- session persistence, reliable updates — pts/qts gap detection, `getDifference` recovery across restarts
- peer cache with username resolution

## usage

handlers are `fn(ctx: Context, update: T) !void`. use `tz.Msg` to work with messages:

```zig
const h = tz.helpers;

fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = tz.Msg.from(ctx, update) orelse return;
    try msg.reply("hello");
}

fn onCallback(ctx: tz.Context, update: tg.UpdateBotCallbackQuery) !void {
    try h.answerCallbackQuery(ctx, update, .{ .text = "clicked!" });
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onMessage),
    tz.handler(tg.UpdateBotCallbackQuery, onCallback),
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

`tz.Msg` wraps `ctx` + the concrete `Message_` struct. accessors: `text()`, `id()`, `date()`, `peer()`, `senderId()`, `replyToId()`, `mediaLocation()`, `is(s)`, `prefix(s)`, `contains(s)`. active operations: `reply(text)`, `respond(text)`, `replyFmt(text, entities)`. raw access via `msg.raw` and `msg.ctx`.

`respond` sends to the same peer without a reply thread. `reply` sets `reply_to` so clients show the quote.

command routing is plain zig:

```zig
fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = tz.Msg.from(ctx, update) orelse return;
    if (msg.is("/start")) return onStart(msg);
    if (msg.prefix("/echo ")) return onEcho(msg);
}
```

call any tl function directly through `ctx`. `call` returns a `Response(T)`, `exec` discards the reply:

```zig
const resp = try ctx.call(f.users.GetUsers{ .id = &id_input });
defer resp.deinit();

try ctx.exec(f.messages.SendMessage{ .peer = peer, .message = "hi" });
```

helpers — media, reactions, pins, edits — take `msg` directly:

```zig
try h.media.sendPhoto(msg, jpeg_bytes, .{});
try h.media.sendDocument(msg, pdf_bytes, "application/pdf", .{ .caption = "report" });
try h.media.sendAudio(msg, mp3_bytes, "audio/mpeg", .{ .title = "Track", .performer = "Artist" });
try h.media.sendVideo(msg, mp4_bytes, "video/mp4", .{});
try h.media.sendVoice(msg, ogg_bytes, .{});
try h.forwardMessages(msg.ctx, from_peer, to_peer, &[_]i32{target_id});
try h.pinMessage(msg.ctx, msg.peer().?, target_id, .{});
try h.addReaction(msg.ctx, msg.peer().?, msg.id(), "❤");
```

formatted text:

```zig
var ft = h.FormattedText.init(msg.ctx.allocator);
defer ft.deinit();
try ft.bold("hello"); try ft.plain(" world");
try msg.replyFmt(ft.text.items, ft.entities.items);
```

file download — streaming or all-at-once:

```zig
// streaming
var file = tz.File.init(msg.ctx, msg.mediaLocation().?);
defer file.deinit();
while (try file.next()) |chunk| { ... }

// all at once
const bytes = try h.download(msg.ctx, msg.mediaLocation().?);
defer msg.ctx.allocator.free(bytes);
```

other update types follow the same pattern — any `UpdateXxx` from the TL schema:

```zig
fn onCallback(ctx: tz.Context, update: tg.UpdateBotCallbackQuery) !void {
    try h.answerCallbackQuery(ctx, update, .{ .text = "clicked!" });
}

fn onInlineQuery(ctx: tz.Context, update: tg.UpdateBotInlineQuery) !void {
    try h.answerInlineQuery(ctx, update, &results, .{});
}

fn onEditedMessage(ctx: tz.Context, update: tg.UpdateEditMessage) !void {
    _ = ctx; _ = update;
}

const handlers = &.{
    tz.handler(tg.UpdateNewMessage, onMessage),
    tz.handler(tg.UpdateBotCallbackQuery, onCallback),
    tz.handler(tg.UpdateBotInlineQuery, onInlineQuery),
    tz.handler(tg.UpdateEditMessage, onEditedMessage),
};
```

username resolution (cache-first, falls back to RPC):

```zig
const peer = try msg.ctx.resolveUsername("username");
```

## memory

whatever you hand to `Client.init` owns everything.

- `call` gives a `Response(T)`. its data and everything under it sit in one arena. `resp.deinit()` when you're done. `exec` if you don't need the reply.
- helpers that return things (`getMe`, `getUsers`, `getChats`, `getChannels`) are the same — `Response(T)`, `deinit()` when done.
- borrowed slices (a photo's `file_reference`, a `first_name`) point into the response arena. keep the `Response` alive while you use them.
- `h.download` returns a plain `[]u8` off `ctx.allocator`. free it yourself.
- handlers only borrow. `msg.raw` and `msg.ctx.entities` are gone once the handler returns. copy out what you keep.

```zig
// hold staged upload responses until after SendMultiMedia — file_references live in their arenas
var staged: [n]tz.Response(f.messages.UploadMedia.Response) = undefined;
defer for (&staged) |s| s.deinit();
for (urls, 0..) |url, i| {
    staged[i] = try msg.ctx.call(f.messages.UploadMedia{ ... });
    multi[i] = .{ .media = inputFrom(staged[i].value), ... };
}
try msg.ctx.exec(f.messages.SendMultiMedia{ .multi_media = &multi });
```

see [examples/](examples/).
