const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const client = @import("client.zig");

const Context = client.Context;

const bigThreshold = 10 * 1024 * 1024; // 10 MB
const partSize = 128 * 1024; // 128 KB

pub const UploadOptions = struct {
    name: []const u8 = "file",
};

/// Upload bytes to Telegram. Returns a types.InputFile ready for use in SendMedia.
/// For small files (≤10MB), the returned InputFile.md5_checksum is heap-allocated —
/// caller must free it: ctx.allocator.free(result.InputFile.md5_checksum).
/// For large files the InputFileBig variant is returned and no extra free is needed.
pub fn upload(ctx: Context, data: []const u8, opts: UploadOptions) !types.InputFile {
    const file_id = client.nextRandomId();
    const n_parts: i32 = @intCast((data.len + partSize - 1) / partSize);
    const is_big = data.len > bigThreshold;

    for (0..@intCast(n_parts)) |i| {
        const start = i * partSize;
        const end = @min(start + partSize, data.len);
        const chunk = data[start..end];

        if (is_big) {
            _ = try ctx.callFile(functions.upload.SaveBigFilePart{
                .file_id = file_id,
                .file_part = @intCast(i),
                .file_total_parts = n_parts,
                .bytes = chunk,
            });
        } else {
            _ = try ctx.callFile(functions.upload.SaveFilePart{
                .file_id = file_id,
                .file_part = @intCast(i),
                .bytes = chunk,
            });
        }
    }

    if (is_big) {
        return .{ .InputFileBig = .{
            .id = file_id,
            .parts = n_parts,
            .name = opts.name,
        } };
    }

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const md5_hex = try std.fmt.allocPrint(ctx.allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
    return .{ .InputFile = .{
        .id = file_id,
        .parts = n_parts,
        .name = opts.name,
        .md5_checksum = md5_hex,
    } };
}
