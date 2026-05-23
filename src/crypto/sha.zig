const std = @import("std");

pub fn sha1(data: []const u8) [20]u8 {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &out, .{});
    return out;
}

pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn sha256Cat(a: []const u8, b: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(a);
    h.update(b);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn sha1Cat(parts: []const []const u8) [20]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    for (parts) |p| h.update(p);
    var out: [20]u8 = undefined;
    h.final(&out);
    return out;
}

test "sha256 known answer" {
    const digest = sha256("abc");
    const expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".*;
    var expected_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_bytes, &expected);
    try std.testing.expectEqualSlices(u8, &expected_bytes, &digest);
}

test "sha1 known answer" {
    const digest = sha1("abc");
    const expected = "a9993e364706816aba3e25717850c26c9cd0d89d".*;
    var expected_bytes: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_bytes, &expected);
    try std.testing.expectEqualSlices(u8, &expected_bytes, &digest);
}
