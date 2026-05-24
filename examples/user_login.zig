//! user_login — interactive phone-number login example.
//! usage: TZ_API_ID=<id> TZ_API_HASH=<hash> zig build user-login

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
    const from = switch (msg.peer_id) {
        .PeerUser => |p| p.user_id,
        else => 0,
    };
    std.log.info("msg from {}: {s}", .{ from, msg.message });
}

const Client = tz.Client(&.{
    tz.handler(tg.UpdateNewMessage, onNewMessage),
});

fn prompt(io: std.Io, label: []const u8, buf: []u8) ![]const u8 {
    std.log.info("{s}", .{label});
    var r = std.Io.File.stdin().reader(io, buf);
    const line = try r.interface.takeDelimiterExclusive('\n');
    return std.mem.trim(u8, line, "\r\n ");
}

fn handle2FA(client: *Client, io: std.Io) !void {
    const pwd = try client.call(io, functions.account.GetPassword{});

    const algo = switch (pwd.current_algo.value orelse return error.NoPassword) {
        .PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow => |a| a,
        else => return error.UnsupportedPasswordAlgo,
    };
    const srp_B = pwd.srp_B.value orelse return error.NoPassword;
    const srp_id = pwd.srp_id.value orelse return error.NoPassword;

    var pw_buf: [128]u8 = undefined;
    const password = try prompt(io, "2FA password: ", &pw_buf);

    std.log.info("computing 2FA key (may take a few seconds)...", .{});
    const answer = try tz.crypto.srp.compute(
        client.allocator,
        io,
        algo.salt1,
        algo.salt2,
        algo.g,
        algo.p,
        srp_B,
        password,
    );

    const auth = try client.call(io, functions.auth.CheckPassword{
        .password = tg.InputCheckPasswordSRP{ .InputCheckPasswordSRP = .{
            .srp_id = srp_id,
            .A = &answer.A,
            .M1 = &answer.M1,
        } },
    });
    logAuth(auth);
}

fn logAuth(auth: tg.AuthAuthorization) void {
    switch (auth) {
        .AuthAuthorization => |a| switch (a.user) {
            .User => |u| std.log.info("logged in as id={} username={s}", .{
                u.id,
                u.username.value orelse "(none)",
            }),
            else => std.log.info("logged in", .{}),
        },
        .AuthAuthorizationSignUpRequired => std.log.warn(
            "number not registered; call auth.SignUp to create account",
            .{},
        ),
    }
}

fn userAuth(ptr: *anyopaque, io: std.Io) anyerror!void {
    const client: *Client = @ptrCast(@alignCast(ptr));

    var phone_r_buf: [64]u8 = undefined;
    const phone = try prompt(io, "phone number (+12345): ", &phone_r_buf);

    const sent = try client.call(io, functions.auth.SendCode{
        .phone_number = phone,
        .api_id = client.opts.api_id,
        .api_hash = client.opts.api_hash,
        .settings = .{},
    });

    const code_hash: []const u8 = switch (sent) {
        .AuthSentCode => |s| s.phone_code_hash,
        .AuthSentCodeSuccess => {
            std.log.info("already authorized", .{});
            return;
        },
        .AuthSentCodePaymentRequired => return error.PaymentRequired,
    };
    defer client.allocator.free(code_hash);

    var code_r_buf: [32]u8 = undefined;
    const code = try prompt(io, "verification code: ", &code_r_buf);

    const auth = client.call(io, functions.auth.SignIn{
        .phone_number = phone,
        .phone_code_hash = code_hash,
        .phone_code = .some(code),
    }) catch |err| switch (err) {
        error.SessionPasswordNeeded => {
            try handle2FA(client, io);
            return;
        },
        else => return err,
    };

    logAuth(auth);
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
