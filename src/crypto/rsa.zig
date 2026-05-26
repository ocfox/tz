const std = @import("std");
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;

/// result = base^exp mod mod (square-and-multiply)
pub fn modPow(result: *Managed, base: *const Managed, exp: *const Managed, mod: *const Managed, allocator: Allocator) !void {
    var r = try Managed.initSet(allocator, 1);
    defer r.deinit();
    var b = try base.clone();
    defer b.deinit();
    var e = try exp.clone();
    defer e.deinit();
    var q = try Managed.init(allocator);
    defer q.deinit();
    var rem = try Managed.init(allocator);
    defer rem.deinit();
    var tmp = try Managed.init(allocator);
    defer tmp.deinit();

    // b = base mod m
    try q.divFloor(&rem, &b, mod);
    try b.copy(rem.toConst());

    while (!e.eqlZero()) {
        if (e.isOdd()) {
            try tmp.mul(&r, &b);
            try q.divFloor(&rem, &tmp, mod);
            try r.copy(rem.toConst());
        }
        // e >>= 1  (use q as tmp — it gets overwritten by divFloor each iteration)
        try q.shiftRight(&e, 1);
        try e.copy(q.toConst());
        // b = b^2 mod m
        try tmp.sqr(&b);
        try q.divFloor(&rem, &tmp, mod);
        try b.copy(rem.toConst());
    }
    try result.copy(r.toConst());
}

/// RSA encrypt: c = m^e mod n, e=65537.
/// msg is 255 bytes (padded payload), n_bytes is 256-byte big-endian modulus.
pub fn rsaEncrypt(
    out: *[256]u8,
    msg: *const [255]u8,
    n_bytes: *const [256]u8,
    allocator: Allocator,
) !void {
    var m = try Managed.init(allocator);
    defer m.deinit();
    var n = try Managed.init(allocator);
    defer n.deinit();
    var e_val = try Managed.initSet(allocator, 65537);
    defer e_val.deinit();
    var result = try Managed.init(allocator);
    defer result.deinit();

    // prepend 0x00 so 255-byte msg fits in 256-byte big-endian representation
    var m_bytes: [256]u8 = undefined;
    m_bytes[0] = 0;
    @memcpy(m_bytes[1..], msg);
    try setFromBigEndianBytes(&m, &m_bytes);
    try setFromBigEndianBytes(&n, n_bytes);

    try modPow(&result, &m, &e_val, &n, allocator);

    try bigEndianBytes(&result, out, allocator);
}

pub fn setFromBigEndianBytes(m: *Managed, bytes: []const u8) !void {
    std.debug.assert(bytes.len <= 256);
    var hex: [512]u8 = undefined;
    for (bytes, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch @panic("hex buf too small");
    }
    try m.setString(16, hex[0 .. bytes.len * 2]);
}

pub fn bigEndianBytes(m: *const Managed, out: []u8, allocator: Allocator) !void {
    const hex = try m.toString(allocator, 16, .lower);
    defer allocator.free(hex);
    const padded_len = out.len * 2;
    std.debug.assert(padded_len <= 512);
    var hex_buf: [512]u8 = undefined;
    @memset(hex_buf[0..padded_len], '0');
    if (hex.len <= padded_len) {
        @memcpy(hex_buf[padded_len - hex.len .. padded_len], hex);
    }
    _ = try std.fmt.hexToBytes(out, hex_buf[0..padded_len]);
}

test "modPow small values" {
    const allocator = std.testing.allocator;
    var base = try Managed.initSet(allocator, 2);
    defer base.deinit();
    var exp = try Managed.initSet(allocator, 10);
    defer exp.deinit();
    var mod = try Managed.initSet(allocator, 1000);
    defer mod.deinit();
    var result = try Managed.init(allocator);
    defer result.deinit();
    // 2^10 mod 1000 = 1024 mod 1000 = 24
    try modPow(&result, &base, &exp, &mod, allocator);
    try std.testing.expectEqual(@as(u64, 24), try result.toInt(u64));
}

test "modPow larger exponent" {
    const allocator = std.testing.allocator;
    var base = try Managed.initSet(allocator, 3);
    defer base.deinit();
    var exp = try Managed.initSet(allocator, 100);
    defer exp.deinit();
    var mod = try Managed.initSet(allocator, 97);
    defer mod.deinit();
    var result = try Managed.init(allocator);
    defer result.deinit();
    // 3^100 mod 97: Fermat's little theorem, 3^96 ≡ 1 mod 97, so 3^100 = 3^4 = 81
    try modPow(&result, &base, &exp, &mod, allocator);
    try std.testing.expectEqual(@as(u64, 81), try result.toInt(u64));
}
