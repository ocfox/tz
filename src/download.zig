const std = @import("std");
const types = @import("types");
const functions = @import("functions");
const client_mod = @import("client.zig");

const Context = client_mod.Context;

const chunk_size: i32 = 512 * 1024;

/// Download a file by InputFileLocation. Returns heap-allocated bytes; caller must free.
/// FILE_MIGRATE errors are handled automatically via ctx.callFile.
pub fn download(ctx: Context, location: types.InputFileLocation) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.allocator);

    var offset: i64 = 0;
    while (true) {
        const result = try ctx.callFile(functions.upload.GetFile{
            .location = location,
            .offset = offset,
            .limit = chunk_size,
        });
        const chunk = switch (result) {
            .UploadFile => |f| f.bytes,
            .UploadFileCdnRedirect => return error.CdnRedirectUnsupported,
        };
        try buf.appendSlice(ctx.allocator, chunk);
        if (chunk.len < @as(usize, @intCast(chunk_size))) break;
        offset += @intCast(chunk.len);
    }

    return buf.toOwnedSlice(ctx.allocator);
}

/// Extract InputFileLocation from a Document. Returns null for empty/unknown variants.
pub fn documentLocation(doc: types.Document) ?types.InputFileLocation {
    const d = switch (doc) {
        .Document => |d| d,
        else => return null,
    };
    return .{ .InputDocumentFileLocation = .{
        .id = d.id,
        .access_hash = d.access_hash,
        .file_reference = d.file_reference,
        .thumb_size = "",
    } };
}

/// Extract InputFileLocation from a Photo, selecting the largest available size.
/// Returns null for empty/unknown photo variants or if no downloadable size exists.
pub fn photoLocation(photo: types.Photo) ?types.InputFileLocation {
    const p = switch (photo) {
        .Photo => |p| p,
        else => return null,
    };
    var best_type: ?[]const u8 = null;
    var best_size: i32 = -1;
    for (p.sizes) |ps| {
        switch (ps) {
            .PhotoSize => |s| if (s.size > best_size) {
                best_size = s.size;
                best_type = s.type;
            },
            .PhotoSizeProgressive => |s| {
                const last = if (s.sizes.len > 0) s.sizes[s.sizes.len - 1] else continue;
                if (last > best_size) {
                    best_size = last;
                    best_type = s.type;
                }
            },
            else => {},
        }
    }
    const size_type = best_type orelse return null;
    return .{ .InputPhotoFileLocation = .{
        .id = p.id,
        .access_hash = p.access_hash,
        .file_reference = p.file_reference,
        .thumb_size = size_type,
    } };
}
