const std = @import("std");
const aes = std.crypto.core.aes;

// AES-256-CTR as used by Telegram CDN encryption.
// The counter occupies the last 4 bytes of the 16-byte IV block, big-endian.
// Chunks at file offset `off` start with counter = base_counter + off/16.

pub fn decrypt(key: [32]u8, base_iv: [16]u8, data: []u8, file_offset: u64) void {
    const ctx = aes.AesEncryptCtx(aes.Aes256).init(key);

    var counter: [16]u8 = base_iv;
    const base_ctr = std.mem.readInt(u32, counter[12..16], .big);
    std.mem.writeInt(u32, counter[12..16], base_ctr +% @as(u32, @intCast(file_offset / 16)), .big);

    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        var ks: [16]u8 = undefined;
        ctx.encrypt(&ks, &counter);
        for (data[i..][0..16], &ks) |*d, k| d.* ^= k;
        const c = std.mem.readInt(u32, counter[12..16], .big);
        std.mem.writeInt(u32, counter[12..16], c +% 1, .big);
    }
    if (i < data.len) {
        var ks: [16]u8 = undefined;
        ctx.encrypt(&ks, &counter);
        for (data[i..], ks[0 .. data.len - i]) |*d, k| d.* ^= k;
    }
}

test "aes_ctr: self-inverse" {
    var key: [32]u8 = undefined;
    var iv: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    for (&iv, 0..) |*b, i| b.* = @intCast(i + 32);
    var data = [_]u8{0xab} ** 64;
    const original = data;
    decrypt(key, iv, &data, 0);
    try std.testing.expect(!std.mem.eql(u8, &data, &original));
    decrypt(key, iv, &data, 0);
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "aes_ctr: offset continuity" {
    var key: [32]u8 = undefined;
    var iv: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    for (&iv, 0..) |*b, i| b.* = @intCast(i + 32);
    var full = [_]u8{0xab} ** 64;
    decrypt(key, iv, &full, 0);
    var first = [_]u8{0xab} ** 32;
    var second = [_]u8{0xab} ** 32;
    decrypt(key, iv, &first, 0);
    decrypt(key, iv, &second, 32);
    try std.testing.expectEqualSlices(u8, full[0..32], &first);
    try std.testing.expectEqualSlices(u8, full[32..64], &second);
}
