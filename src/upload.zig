const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const client_mod = @import("client.zig");

const Context = client_mod.Context;

const big_threshold = 10 * 1024 * 1024; // 10 MB
const part_size = 128 * 1024; // 128 KB

pub const UploadOptions = struct {
    name: []const u8 = "file",
};

/// Upload bytes to Telegram. Returns a types.InputFile ready for use in SendMedia.
/// For small files (≤10MB), the returned InputFile.md5_checksum is heap-allocated —
/// caller must free it: ctx.allocator.free(result.InputFile.md5_checksum).
/// For large files the InputFileBig variant is returned and no extra free is needed.
pub fn upload(ctx: Context, data: []const u8, opts: UploadOptions) !types.InputFile {
    const file_id = client_mod.nextRandomId();
    const n_parts: i32 = @intCast((data.len + part_size - 1) / part_size);
    const is_big = data.len > big_threshold;

    var i: i32 = 0;
    while (i < n_parts) : (i += 1) {
        const start = @as(usize, @intCast(i)) * part_size;
        const end = @min(start + part_size, data.len);
        const chunk = data[start..end];

        if (is_big) {
            _ = try ctx.callFile(functions.upload.SaveBigFilePart{
                .file_id = file_id,
                .file_part = i,
                .file_total_parts = n_parts,
                .bytes = chunk,
            });
        } else {
            _ = try ctx.callFile(functions.upload.SaveFilePart{
                .file_id = file_id,
                .file_part = i,
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
    const md5_hex = try std.fmt.allocPrint(ctx.allocator, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
    return .{ .InputFile = .{
        .id = file_id,
        .parts = n_parts,
        .name = opts.name,
        .md5_checksum = md5_hex,
    } };
}
