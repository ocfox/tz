const std = @import("std");
const tz = @import("tz");

// Run with: TZ_TEST_DC=1 zig build test
test "auth key exchange — Telegram test DC2" {
    if (std.c.getenv("TZ_TEST_DC") == null) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Telegram test server DC2
    const addr = std.Io.net.IpAddress.parseIp4("149.154.167.40", 443) catch unreachable;
    const stream = try addr.connect(io, .{ .mode = .stream });
    var transport = tz.transport.tcp.AnyTransport{ .tcp = tz.transport.tcp.TcpTransport.init(stream, .abridged) };

    const result = try tz.session.auth_key.perform(&transport, io, std.testing.allocator);

    // auth_key_id must be non-zero and auth_key must not be all zeros
    try std.testing.expect(result.auth_key_id != 0);
    const all_zero = std.mem.allEqual(u8, &result.auth_key, 0);
    try std.testing.expect(!all_zero);

    std.log.info("auth_key_id = {x}", .{result.auth_key_id});
    std.log.info("server_salt = {x}", .{result.server_salt});
    std.log.info("time_offset = {}s", .{result.time_offset});
}
