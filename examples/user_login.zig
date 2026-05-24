//! user_login — demonstrates user account auth via auth_fn.
//!
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> zig build user-login

const std = @import("std");
const tz = @import("tz");
const tg = tz.types;
const functions = @import("functions");

// The constants below are left as-is on purpose. It's up to you to
// implement how they are interactively provided—do it in your own style.
const phone = "+12345678900";
const code = "12345";
const phone_code_hash = "abc123"; // returned by auth.SendCode
const password_2fa = "hunter2"; // only needed if account has 2FA

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

fn userAuth(ptr: *anyopaque, io: std.Io) anyerror!void {
    const client: *Client = @ptrCast(@alignCast(ptr));

    // Step 1: request a code
    _ = try client.call(io, functions.auth.SendCode{
        .phone_number = phone,
        .api_id = client.opts.api_id,
        .api_hash = client.opts.api_hash,
        .settings = .{},
    });

    // Step 2: sign in with the received code
    _ = client.call(io, functions.auth.SignIn{
        .phone_number = phone,
        .phone_code_hash = phone_code_hash,
        .phone_code = .some(code),
    }) catch |err| switch (err) {
        error.SessionPasswordNeeded => return signIn2FA(client, io),
        else => return err,
    };
}

fn signIn2FA(client: *Client, io: std.Io) !void {
    const pwd = try client.call(io, functions.account.GetPassword{});

    const algo = switch (pwd.current_algo.value orelse return error.NoPassword) {
        .PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow => |a| a,
        else => return error.UnsupportedPasswordAlgo,
    };

    const answer = try tz.crypto.srp.compute(
        client.allocator,
        io,
        algo.salt1,
        algo.salt2,
        algo.g,
        algo.p,
        pwd.srp_B.value orelse return error.NoPassword,
        password_2fa,
    );

    _ = try client.call(io, functions.auth.CheckPassword{
        .password = .{ .InputCheckPasswordSRP = .{
            .srp_id = pwd.srp_id.value orelse return error.NoPassword,
            .A = &answer.A,
            .M1 = &answer.M1,
        } },
    });
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var file_storage = tz.FileStorage.init("user_login.session");

    const client = try Client.init(allocator, .{
        .api_id = try std.fmt.parseInt(i32, std.mem.span(std.c.getenv("TZ_API_ID") orelse usage()), 10),
        .api_hash = std.mem.span(std.c.getenv("TZ_API_HASH") orelse usage()),
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
