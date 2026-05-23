const std = @import("std");
const aes = std.crypto.core.aes;
const Aes256 = aes.Aes256;

// AES-256-IGE as used by Telegram MTProto.
// IV layout: iv[0:16] = c_0 (ciphertext chain), iv[16:32] = m_0 (message chain).
//
// Encrypt: C_i = AES_enc(P_i XOR c_{i-1}) XOR m_{i-1}; then c_i = C_i, m_i = P_i
// Decrypt: P_i = AES_dec(C_i XOR m_{i-1}) XOR c_{i-1}; then m_i = P_i, c_i = C_i

pub fn encrypt(key: [32]u8, iv: [32]u8, data: []u8) void {
    std.debug.assert(data.len % 16 == 0);
    const ctx = aes.AesEncryptCtx(Aes256).init(key);
    var c = iv[0..16].*;
    var m = iv[16..32].*;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const plain = data[i..][0..16].*;
        var xored: [16]u8 = undefined;
        for (&xored, plain, c) |*o, p, cv| o.* = p ^ cv;
        var enc: [16]u8 = undefined;
        ctx.encrypt(&enc, &xored);
        for (data[i..][0..16], enc, m) |*o, e, mv| o.* = e ^ mv;
        c = data[i..][0..16].*;
        m = plain;
    }
}

pub fn decrypt(key: [32]u8, iv: [32]u8, data: []u8) void {
    std.debug.assert(data.len % 16 == 0);
    const ctx = aes.AesDecryptCtx(Aes256).init(key);
    var c = iv[0..16].*;
    var m = iv[16..32].*;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const cipher = data[i..][0..16].*;
        var xored: [16]u8 = undefined;
        for (&xored, cipher, m) |*o, cv, mv| o.* = cv ^ mv;
        var dec: [16]u8 = undefined;
        ctx.decrypt(&dec, &xored);
        for (data[i..][0..16], dec, c) |*o, d, cv| o.* = d ^ cv;
        m = data[i..][0..16].*;
        c = cipher;
    }
}

test "aes_ige encrypt/decrypt roundtrip" {
    var key: [32]u8 = undefined;
    var iv: [32]u8 = undefined;
    var data: [48]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    for (&iv, 0..) |*b, i| b.* = @intCast(i + 32);
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);
    const original = data;
    encrypt(key, iv, &data);
    try std.testing.expect(!std.mem.eql(u8, &data, &original));
    decrypt(key, iv, &data);
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "aes_ige known-answer — Telegram auth_key spec vector" {
    // From https://core.telegram.org/mtproto/samples-auth_key
    // key  = F011280887C7BB01DF0FC4E17830E0B91FBB8BE4B2267CB985AE25F33B527253
    // iv   = 3212D579EE35452ED23E0D0C92841AA7D31B2E9BDEF2151E80D15860311C85DB
    // First 16 bytes of encrypted_answer:
    //   28A92FE20173B347A8BB324B5FAB2667
    // Decrypts to first 16 bytes of answer_with_hash = SHA1(answer)[0:16]:
    //   4B0AF668CF60A358233F93B7341FCA7E
    var key: [32]u8 = undefined;
    var iv: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "F011280887C7BB01DF0FC4E17830E0B91FBB8BE4B2267CB985AE25F33B527253");
    _ = try std.fmt.hexToBytes(&iv, "3212D579EE35452ED23E0D0C92841AA7D31B2E9BDEF2151E80D15860311C85DB");
    var block: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&block, "28A92FE20173B347A8BB324B5FAB2667");
    decrypt(key, iv, &block);
    var expected: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "4B0AF668CF60A358233F93B7341FCA7E");
    try std.testing.expectEqualSlices(u8, &expected, &block);
}
