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

call any tl function directly. `call` hands back a `Response(T)`. `deinit()` when done,
data's in `resp.value`. `exec` if you don't need the reply.

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

## memory

whatever you hand to `Client.init` owns everything.

- `call` gives a `Response(T)`. its data and everything under it sit in one arena. `resp.deinit()` when you're done, it all goes. the data's in `resp.value`. don't need the reply, use `exec`. nothing to free, no decode.
- the helpers that return things (`getMe`, `getUsers`, `getChats`, `getChannels`) are the same. `Response(T)`, `deinit()` when done. the slice lives in the arena. gone after deinit.
- borrowed slices (a photo's `file_reference`, a `first_name`) point into the response arena. keep the `Response` while you use them.
- `h.download` is different. plain `[]u8` off `ctx.allocator`. free it yourself.
- handlers only borrow. the `update` and `ctx.entities` are gone once the handler returns. copy out what you keep.
- `ctx.allocator` is there for scratch.

```zig
// a response owns its data; deinit frees the whole tree at once
const resp = try h.getUsers(ctx, ids);
defer resp.deinit();
for (resp.value) |user| log(user); // borrowed — valid only until deinit

// staging several uploads for one sendMultiMedia: the file_references live
// in each response's arena, so hold them all until after the send
var staged: [n]tz.Response(f.messages.UploadMedia.Response) = undefined;
defer for (&staged) |s| s.deinit();
for (urls, 0..) |url, i| {
    staged[i] = try ctx.call(f.messages.UploadMedia{ ... });
    multi[i] = .{ .media = inputFrom(staged[i].value), ... }; // borrows file_reference
}
try ctx.exec(f.messages.SendMultiMedia{ .multi_media = &multi }); // refs still alive

// handler data is freed on return — copy out what you keep
fn onMessage(ctx: tz.Context, update: tg.UpdateNewMessage) !void {
    const text = try ctx.allocator.dupe(u8, update.message.Message.message);
    // ... stash `text` somewhere; you own it now, free it later
}
```

see [examples/](examples/).
