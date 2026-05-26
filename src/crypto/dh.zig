const std = @import("std");
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const rsa = @import("rsa.zig");

pub const DhParams = struct {
    dh_prime: [256]u8, // 2048-bit prime, big-endian
    g: u32, // generator (usually 2, 3, or 5)
};

pub const DhResult = struct {
    g_b: [256]u8, // g^b mod p, big-endian, send to server
    secret: [256]u8, // g_a^b mod p, big-endian, the auth key
};

pub fn compute(
    params: DhParams,
    g_a: *const [256]u8, // server's g^a mod p
    b_bytes: *const [256]u8, // caller-provided random exponent
    allocator: Allocator,
) !DhResult {
    var b = try Managed.init(allocator);
    defer b.deinit();
    var g_val = try Managed.initSet(allocator, params.g);
    defer g_val.deinit();
    var p = try Managed.init(allocator);
    defer p.deinit();
    var ga = try Managed.init(allocator);
    defer ga.deinit();
    var gb = try Managed.init(allocator);
    defer gb.deinit();
    var secret = try Managed.init(allocator);
    defer secret.deinit();

    try rsa.setFromBigEndianBytes(&b, b_bytes);
    try rsa.setFromBigEndianBytes(&p, &params.dh_prime);
    try rsa.setFromBigEndianBytes(&ga, g_a);

    // g_b = g^b mod p
    try rsa.modPow(&gb, &g_val, &b, &p, allocator);
    // secret = g_a^b mod p
    try rsa.modPow(&secret, &ga, &b, &p, allocator);

    // SAFETY: both fields fully written by bigEndianBytes before return
    var result: DhResult = undefined;
    try rsa.bigEndianBytes(&gb, &result.g_b, allocator);
    try rsa.bigEndianBytes(&secret, &result.secret, allocator);
    return result;
}

test "dh compute produces valid g_b" {
    const allocator = std.testing.allocator;
    // Use small test params: p=23, g=5, g_a=8
    var params: DhParams = undefined;
    @memset(&params.dh_prime, 0);
    params.dh_prime[255] = 23;
    params.g = 5;
    var g_a: [256]u8 = undefined;
    @memset(&g_a, 0);
    g_a[255] = 8;
    var b_bytes: [256]u8 = undefined;
    @memset(&b_bytes, 0);
    b_bytes[255] = 7; // fixed test exponent
    const result = try compute(params, &g_a, &b_bytes, allocator);
    // g_b should be non-zero
    var all_zero = true;
    for (result.g_b) |byte| if (byte != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
    // secret should also be non-zero
    all_zero = true;
    for (result.secret) |byte| if (byte != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}
