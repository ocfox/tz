const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tcp = @import("../transport/tcp.zig");
const sha = @import("../crypto/sha.zig");
const rsa = @import("../crypto/rsa.zig");
const dh = @import("../crypto/dh.zig");
const ser = @import("codec").serialize;
const de = @import("codec").deserialize;

const server_key_n: [256]u8 = .{
    0xc1, 0x50, 0x02, 0x3e, 0x2f, 0x70, 0xdb, 0x79, 0x85, 0xde, 0xd0, 0x64, 0x75, 0x9c, 0xfe, 0xcf,
    0x0a, 0xf3, 0x28, 0xe6, 0x9a, 0x41, 0xda, 0xf4, 0xd6, 0xf0, 0x1b, 0x53, 0x81, 0x35, 0xa6, 0xf9,
    0x1f, 0x8f, 0x8b, 0x2a, 0x0e, 0xc9, 0xba, 0x97, 0x20, 0xce, 0x35, 0x2e, 0xfc, 0xf6, 0xc5, 0x68,
    0x0f, 0xfc, 0x42, 0x4b, 0xd6, 0x34, 0x86, 0x49, 0x02, 0xde, 0x0b, 0x4b, 0xd6, 0xd4, 0x9f, 0x4e,
    0x58, 0x02, 0x30, 0xe3, 0xae, 0x97, 0xd9, 0x5c, 0x8b, 0x19, 0x44, 0x2b, 0x3c, 0x0a, 0x10, 0xd8,
    0xf5, 0x63, 0x3f, 0xec, 0xed, 0xd6, 0x92, 0x6a, 0x7f, 0x6d, 0xab, 0x0d, 0xdb, 0x7d, 0x45, 0x7f,
    0x9e, 0xa8, 0x1b, 0x84, 0x65, 0xfc, 0xd6, 0xff, 0xfe, 0xed, 0x11, 0x40, 0x11, 0xdf, 0x91, 0xc0,
    0x59, 0xca, 0xed, 0xaf, 0x97, 0x62, 0x5f, 0x6c, 0x96, 0xec, 0xc7, 0x47, 0x25, 0x55, 0x69, 0x34,
    0xef, 0x78, 0x1d, 0x86, 0x6b, 0x34, 0xf0, 0x11, 0xfc, 0xe4, 0xd8, 0x35, 0xa0, 0x90, 0x19, 0x6e,
    0x9a, 0x5f, 0x0e, 0x44, 0x49, 0xaf, 0x7e, 0xb6, 0x97, 0xdd, 0xb9, 0x07, 0x64, 0x94, 0xca, 0x5f,
    0x81, 0x10, 0x4a, 0x30, 0x5b, 0x6d, 0xd2, 0x76, 0x65, 0x72, 0x2c, 0x46, 0xb6, 0x0e, 0x5d, 0xf6,
    0x80, 0xfb, 0x16, 0xb2, 0x10, 0x60, 0x7e, 0xf2, 0x17, 0x65, 0x2e, 0x60, 0x23, 0x6c, 0x25, 0x5f,
    0x6a, 0x28, 0x31, 0x5f, 0x40, 0x83, 0xa9, 0x67, 0x91, 0xd7, 0x21, 0x4b, 0xf6, 0x4c, 0x1d, 0xf4,
    0xfd, 0x0d, 0xb1, 0x94, 0x4f, 0xb2, 0x6a, 0x2a, 0x57, 0x03, 0x1b, 0x32, 0xee, 0xe6, 0x4a, 0xd1,
    0x5a, 0x8b, 0xa6, 0x88, 0x85, 0xcd, 0xe7, 0x4a, 0x5b, 0xfc, 0x92, 0x0f, 0x6a, 0xbf, 0x59, 0xba,
    0x5c, 0x75, 0x50, 0x63, 0x73, 0xe7, 0x13, 0x0f, 0x90, 0x42, 0xda, 0x92, 0x21, 0x79, 0x25, 0x1f,
};
const server_key_fp: i64 = -4344800451088585951;

pub const AuthKeyResult = struct {
    auth_key: [256]u8,
    auth_key_id: i64,
    server_salt: i64,
    time_offset: i32,
};

fn randU64(io: std.Io) u64 {
    var buf: [8]u8 = undefined;
    io.random(&buf);
    return @bitCast(buf);
}

fn factorPQ(pq: u64, io: std.Io) struct { p: u32, q: u32 } {
    if (pq % 2 == 0) return .{ .p = 2, .q = @intCast(pq / 2) };
    var x: u64 = randU64(io) % (pq - 2) + 2;
    var y = x;
    const c: u64 = randU64(io) % (pq - 1) + 1;
    var d: u64 = 1;
    while (d == 1) {
        x = @intCast((@as(u128, x) * @as(u128, x) + @as(u128, c)) % @as(u128, pq));
        y = @intCast((@as(u128, y) * @as(u128, y) + @as(u128, c)) % @as(u128, pq));
        y = @intCast((@as(u128, y) * @as(u128, y) + @as(u128, c)) % @as(u128, pq));
        d = gcd(if (x > y) x - y else y - x, pq);
    }
    if (d == pq) return factorPQ(pq, io);
    const p: u32 = @intCast(d);
    const q: u32 = @intCast(pq / d);
    return if (p < q) .{ .p = p, .q = q } else .{ .p = q, .q = p };
}

fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

fn readPlainMsg(transport: *tcp.TcpTransport, io: Io, allocator: Allocator) ![]u8 {
    const frame = try transport.readFrame(io, allocator);
    errdefer allocator.free(frame);
    if (frame.len < 20) return error.TooShort;
    const payload_len = std.mem.readInt(u32, frame[16..20], .little);
    if (20 + payload_len > frame.len) return error.BadLength;
    const payload = try allocator.dupe(u8, frame[20..][0..payload_len]);
    allocator.free(frame);
    return payload;
}

fn writePlainMsg(transport: *tcp.TcpTransport, io: Io, payload: []const u8, allocator: Allocator) !void {
    const frame_len = 20 + payload.len;
    const padded = ((frame_len + 3) / 4) * 4;
    std.debug.assert(padded <= 544);
    var frame_buf: [544]u8 = undefined;
    const frame = frame_buf[0..padded];
    @memset(frame, 0);
    _ = allocator;
    std.mem.writeInt(i64, frame[0..8], 0, .little);
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const unix_s = @divTrunc(now_ns, std.time.ns_per_s);
    const frac = @rem(now_ns, std.time.ns_per_s);
    const msg_id = (unix_s << 32) | (@divTrunc(frac, std.time.ns_per_s / 4) * 4);
    std.mem.writeInt(i64, frame[8..16], @intCast(msg_id), .little);
    std.mem.writeInt(u32, frame[16..20], @intCast(payload.len), .little);
    @memcpy(frame[20..][0..payload.len], payload);
    try transport.writeFrame(io, frame);
}

pub fn perform(transport: *tcp.TcpTransport, io: Io, allocator: Allocator) !AuthKeyResult {
    // Step 1: req_pq_multi
    var nonce: [16]u8 = undefined;
    io.random(&nonce);

    var req_buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&req_buf);
    try w.writeInt(u32, 0xbe7e8ef1, .little);
    try w.writeAll(&nonce);
    try writePlainMsg(transport, io, w.buffered(), allocator);

    // Step 2: resPQ
    const res_pq_raw = try readPlainMsg(transport, io, allocator);
    defer allocator.free(res_pq_raw);
    var r: std.Io.Reader = .fixed(res_pq_raw);
    const ctor_id = try r.takeInt(u32, .little);
    if (ctor_id != 0x05162463) return error.UnexpectedResponse;
    var nonce_echo: [16]u8 = undefined;
    try r.readSliceAll(&nonce_echo);
    var server_nonce: [16]u8 = undefined;
    try r.readSliceAll(&server_nonce);
    const pq_bytes = try de.bytes(&r, allocator);
    defer allocator.free(pq_bytes);
    var pq: u64 = 0;
    for (pq_bytes) |b| pq = pq * 256 + b;

    // Step 3: factor pq
    const factors = factorPQ(pq, io);

    // Step 4: p_q_inner_data_dc
    var p_bytes: [4]u8 = undefined;
    var q_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &p_bytes, factors.p, .big);
    std.mem.writeInt(u32, &q_bytes, factors.q, .big);
    var new_nonce: [32]u8 = undefined;
    io.random(&new_nonce);

    var inner_buf: [256]u8 = undefined;
    var iw: std.Io.Writer = .fixed(&inner_buf);
    try iw.writeInt(u32, 0x83c95aec, .little);
    try ser.bytes(&iw, pq_bytes);
    try ser.bytes(&iw, &p_bytes);
    try ser.bytes(&iw, &q_bytes);
    try iw.writeAll(&nonce);
    try iw.writeAll(&server_nonce);
    try iw.writeAll(&new_nonce);

    const inner_data = iw.buffered();
    const inner_hash = sha.sha1(inner_data);
    var rsa_payload: [255]u8 = undefined;
    @memcpy(rsa_payload[0..20], &inner_hash);
    const copy_len = @min(inner_data.len, 235);
    @memcpy(rsa_payload[20..][0..copy_len], inner_data[0..copy_len]);
    io.random(rsa_payload[20 + copy_len ..]);

    var encrypted_data: [256]u8 = undefined;
    try rsa.rsaEncrypt(&encrypted_data, &rsa_payload, server_key_n[0..256], allocator);

    // Step 5: req_DH_params
    var req2_buf: [512]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&req2_buf);
    try w2.writeInt(u32, 0xd712e4be, .little);
    try w2.writeAll(&nonce);
    try w2.writeAll(&server_nonce);
    try ser.bytes(&w2, &p_bytes);
    try ser.bytes(&w2, &q_bytes);
    try w2.writeInt(i64, server_key_fp, .little);
    try ser.bytes(&w2, &encrypted_data);
    try writePlainMsg(transport, io, w2.buffered(), allocator);

    // Step 6: server_DH_params_ok
    const dh_params_raw = try readPlainMsg(transport, io, allocator);
    defer allocator.free(dh_params_raw);
    var dhr: std.Io.Reader = .fixed(dh_params_raw);
    const dh_id = try dhr.takeInt(u32, .little);
    if (dh_id != 0xd0e8075c) return error.DhParamsFailed;
    var skip16: [16]u8 = undefined;
    try dhr.readSliceAll(&skip16);
    try dhr.readSliceAll(&skip16);
    const enc_answer = try de.bytes(&dhr, allocator);
    defer allocator.free(enc_answer);

    // Decrypt server_DH_inner_data
    const sha1_ns = sha.sha1Cat(&.{ &new_nonce, &server_nonce });
    const sha1_sn = sha.sha1Cat(&.{ &server_nonce, &new_nonce });
    const sha1_nn = sha.sha1Cat(&.{ &new_nonce, &new_nonce });
    var tmp_key: [32]u8 = undefined;
    var tmp_iv: [32]u8 = undefined;
    @memcpy(tmp_key[0..20], &sha1_ns);
    @memcpy(tmp_key[20..32], sha1_sn[0..12]);
    @memcpy(tmp_iv[0..8], sha1_sn[12..20]);
    @memcpy(tmp_iv[8..28], &sha1_nn);
    @memcpy(tmp_iv[28..32], new_nonce[0..4]);

    const answer_buf = try allocator.dupe(u8, enc_answer);
    defer allocator.free(answer_buf);
    @import("../crypto/aes_ige.zig").decrypt(tmp_key, tmp_iv, answer_buf);

    var ansr: std.Io.Reader = .fixed(answer_buf[20..]);
    const inner_id = try ansr.takeInt(u32, .little);
    if (inner_id != 0xb5890dba) return error.BadInnerData;
    try ansr.discardAll(16);
    try ansr.discardAll(16);
    const dh_g = try ansr.takeInt(u32, .little);
    const dh_prime_bytes = try de.bytes(&ansr, allocator);
    defer allocator.free(dh_prime_bytes);
    const g_a_bytes = try de.bytes(&ansr, allocator);
    defer allocator.free(g_a_bytes);
    const server_time = try ansr.takeInt(i32, .little);

    // Step 7: compute g_b and shared secret
    var dh_prime: [256]u8 = undefined;
    var g_a: [256]u8 = undefined;
    @memset(&dh_prime, 0);
    @memset(&g_a, 0);
    if (dh_prime_bytes.len <= 256) @memcpy(dh_prime[256 - dh_prime_bytes.len ..], dh_prime_bytes);
    if (g_a_bytes.len <= 256) @memcpy(g_a[256 - g_a_bytes.len ..], g_a_bytes);
    const dh_result = try dh.compute(.{ .dh_prime = dh_prime, .g = dh_g }, &g_a, allocator);

    // Step 8: set_client_DH_params
    var ci_data_buf: [320]u8 = undefined;
    var ciw: std.Io.Writer = .fixed(&ci_data_buf);
    try ciw.writeInt(u32, 0x6643b654, .little);
    try ciw.writeAll(&nonce);
    try ciw.writeAll(&server_nonce);
    try ciw.writeInt(i64, 0, .little);
    try ser.bytes(&ciw, &dh_result.g_b);
    const ci_data = ciw.buffered();
    const ci_hash = sha.sha1(ci_data);

    const ci_total = 20 + ci_data.len;
    const ci_padded_len = ((ci_total + 15) / 16) * 16;
    std.debug.assert(ci_padded_len <= 352);
    var ci_padded_buf: [352]u8 = undefined;
    const ci_padded = ci_padded_buf[0..ci_padded_len];
    @memcpy(ci_padded[0..20], &ci_hash);
    @memcpy(ci_padded[20..][0..ci_data.len], ci_data);
    io.random(ci_padded[20 + ci_data.len ..]);
    @import("../crypto/aes_ige.zig").encrypt(tmp_key, tmp_iv, ci_padded);

    var set_buf: [512]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&set_buf);
    try sw.writeInt(u32, 0xf5045f1f, .little);
    try sw.writeAll(&nonce);
    try sw.writeAll(&server_nonce);
    try ser.bytes(&sw, ci_padded);
    try writePlainMsg(transport, io, sw.buffered(), allocator);

    // Step 9: dh_gen_ok
    const dh_gen_raw = try readPlainMsg(transport, io, allocator);
    defer allocator.free(dh_gen_raw);
    if (dh_gen_raw.len < 4) return error.TooShort;
    const gen_id = std.mem.readInt(u32, dh_gen_raw[0..4], .little);
    if (gen_id != 0x3bcbf734) return error.DhGenFailed;

    const auth_key_hash = sha.sha1(&dh_result.secret);
    var auth_key_id: i64 = undefined;
    @memcpy(std.mem.asBytes(&auth_key_id), auth_key_hash[12..20]);

    var server_salt: i64 = undefined;
    for (std.mem.asBytes(&server_salt), new_nonce[0..8], server_nonce[0..8]) |*o, a, b| o.* = a ^ b;

    return AuthKeyResult{
        .auth_key = dh_result.secret,
        .auth_key_id = auth_key_id,
        .server_salt = server_salt,
        .time_offset = blk: {
            const now_s: i32 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
            break :blk server_time - now_s;
        },
    };
}
