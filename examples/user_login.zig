//! user_login — interactive user account auth via auth_fn.
//!
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> zig build user-login
//!
//! prompts for phone, login code, and (if enabled) the 2FA password on stdin.
//! note: the password is read in plaintext — hiding terminal echo is left out for
//! brevity. fine for a demo, do better in production.

const std = @import("std");
const tz = @import("tz");
const tg = tz.types;
const functions = @import("functions");

fn onNewMessage(_: tz.Context, update: tg.UpdateNewMessage) !void {
    const msg = switch (update.message) {
        .Message => |m| m,
        else => return,
    };
    if (msg.message.len == 0) return;
    std.log.info("msg: {s}", .{msg.message});
}

const Client = tz.Client(&.{
    tz.handler(tg.UpdateNewMessage, onNewMessage),
});

/// Prompt on stderr, read one line from stdin, return an owned, trimmed copy.
fn readLine(allocator: std.mem.Allocator, io: std.Io, in: *std.Io.Reader, label: []const u8) ![]u8 {
    var obuf: [128]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &obuf);
    try ew.interface.writeAll(label);
    try ew.interface.flush();
    const line = try in.takeDelimiterExclusive('\n');
    return allocator.dupe(u8, std.mem.trimEnd(u8, line, "\r \t"));
}

// auth_fn now receives a typed Context — no *anyopaque cast. call TL functions
// through ctx.call / ctx.exec exactly like in an update handler.
fn userAuth(ctx: tz.Context) !void {
    var ibuf: [512]u8 = undefined;
    var fr = std.Io.File.stdin().reader(ctx.io, &ibuf);
    const in = &fr.interface;

    const phone = try readLine(ctx.allocator, ctx.io, in, "phone number (e.g. +12345678900): ");
    defer ctx.allocator.free(phone);

    // step 1: request a code. phone_code_hash comes back in the response.
    const sent = try ctx.call(functions.auth.SendCode{
        .phone_number = phone,
        .api_id = ctx.api_id,
        .api_hash = ctx.api_hash,
        .settings = .{},
    });
    defer sent.deinit();
    const phone_code_hash = switch (sent.value) {
        .AuthSentCode => |s| s.phone_code_hash,
        .AuthSentCodeSuccess => return, // already signed in, no code needed
        .AuthSentCodePaymentRequired => return error.PaymentRequired,
    };

    // step 2: sign in with the code the user just received.
    const code = try readLine(ctx.allocator, ctx.io, in, "login code: ");
    defer ctx.allocator.free(code);

    ctx.exec(functions.auth.SignIn{
        .phone_number = phone,
        .phone_code_hash = phone_code_hash,
        .phone_code = .some(code),
    }) catch |err| switch (err) {
        error.SessionPasswordNeeded => return signIn2FA(ctx, in),
        else => return err,
    };
}

fn signIn2FA(ctx: tz.Context, in: *std.Io.Reader) !void {
    const password = try readLine(ctx.allocator, ctx.io, in, "2FA password: ");
    defer ctx.allocator.free(password);

    const pwd_resp = try ctx.call(functions.account.GetPassword{});
    defer pwd_resp.deinit();
    const pwd = pwd_resp.value;

    const algo = switch (pwd.current_algo.value orelse return error.NoPassword) {
        .PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow => |a| a,
        else => return error.UnsupportedPasswordAlgo,
    };

    const answer = try tz.crypto.srp.compute(
        ctx.allocator,
        ctx.io,
        algo.salt1,
        algo.salt2,
        algo.g,
        algo.p,
        pwd.srp_B.value orelse return error.NoPassword,
        password,
    );

    try ctx.exec(functions.auth.CheckPassword{
        .password = .{ .InputCheckPasswordSRP = .{
            .srp_id = pwd.srp_id.value orelse return error.NoPassword,
            .A = &answer.A,
            .M1 = &answer.M1,
        } },
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var file_storage = tz.Storage.File.init("user_login.session");

    const client = try Client.init(allocator, .{
        .api_id = try std.fmt.parseInt(i32, init.environ.getPosix("TZ_API_ID") orelse usage(), 10),
        .api_hash = init.environ.getPosix("TZ_API_HASH") orelse usage(),
        .auth_fn = userAuth,
        .storage = file_storage.storage(),
    });
    defer client.deinit();

    try client.run(io);
}

fn usage() noreturn {
    std.log.err("usage: TZ_API_ID=<id> TZ_API_HASH=<hash> ./user_login", .{});
    std.process.exit(1);
}
