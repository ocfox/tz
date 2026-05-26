const std = @import("std");
const Allocator = std.mem.Allocator;
const de = @import("deserialize.zig");
const flags_mod = @import("flags.zig");
const isFlag = flags_mod.isFlag;
const isFlags = flags_mod.isFlags;
const isFlags2 = flags_mod.isFlags2;

pub fn decode(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    return switch (@typeInfo(T)) {
        .int => r.takeInt(T, .little),
        .float => blk: {
            const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = try r.takeInt(IntT, .little);
            break :blk @bitCast(bits);
        },
        .bool => blk: {
            const id = try r.takeInt(u32, .little);
            break :blk switch (id) {
                0x997275b5 => true,
                0xbc799737 => false,
                else => error.UnexpectedConstructor,
            };
        },
        .array => |arr| blk: {
            if (arr.child != u8) @compileError("only [N]u8 arrays supported");
            // SAFETY: immediately overwritten by readSliceAll
            var buf: T = undefined;
            try r.readSliceAll(&buf);
            break :blk buf;
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                try de.bytes(r, allocator)
            else
                try decodeVector(ptr.child, r, allocator),
            .one => blk: {
                const p = try allocator.create(ptr.child);
                errdefer allocator.destroy(p);
                p.* = try decode(ptr.child, r, allocator);
                break :blk p;
            },
            else => @compileError("unsupported pointer"),
        },
        .@"struct" => try decodeStruct(T, r, allocator),
        .@"union" => try decodeUnion(T, r, allocator),
        .void => {},
        else => @compileError("unsupported type: " ++ @typeName(T)),
    };
}

pub fn decodeStructBody(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    // SAFETY: every field is written by the inline for loop below before result is returned
    var result: T = undefined;
    var flags_val: u32 = 0;
    var flags2_val: u32 = 0;
    inline for (std.meta.fields(T)) |field| {
        if (comptime isFlags(field.type)) {
            flags_val = try r.takeInt(u32, .little);
            @field(result, field.name) = .{};
        } else if (comptime isFlags2(field.type)) {
            flags2_val = try r.takeInt(u32, .little);
            @field(result, field.name) = .{};
        } else if (comptime isFlag(field.type)) {
            const word_val = if (comptime field.type.flag_word == 0) flags_val else flags2_val;
            const bit = field.type.flag_bit;
            if ((word_val >> bit) & 1 == 1) {
                if (comptime field.type.Inner == void) {
                    @field(result, field.name) = .{ .value = {} };
                } else {
                    const inner = try decode(field.type.Inner, r, allocator);
                    @field(result, field.name) = .{ .value = inner };
                }
            } else {
                @field(result, field.name) = .{ .value = null };
            }
        } else {
            @field(result, field.name) = try decode(field.type, r, allocator);
        }
    }
    return result;
}

fn decodeVector(comptime Child: type, r: *std.Io.Reader, allocator: Allocator) anyerror![]Child {
    const cid = try r.takeInt(u32, .little);
    if (cid != 0x1cb5c415) return error.UnexpectedConstructor;
    const count = try r.takeInt(u32, .little);
    const slice = try allocator.alloc(Child, count);
    errdefer allocator.free(slice);
    for (slice) |*item| item.* = try decode(Child, r, allocator);
    return slice;
}

fn decompressGzip(r: *std.Io.Reader, allocator: Allocator) ![]u8 {
    const compressed = try de.bytes(r, allocator);
    defer allocator.free(compressed);
    var in = std.Io.Reader.fixed(compressed);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    return allocator.dupe(u8, aw.written());
}

fn decodeStruct(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    if (@hasDecl(T, "cid")) {
        const cid = try r.takeInt(u32, .little);
        if (cid == 0x3072cfa1) { // gzip_packed
            const data = try decompressGzip(r, allocator);
            defer allocator.free(data);
            var dr = std.Io.Reader.fixed(data);
            return decodeStruct(T, &dr, allocator);
        }
        if (cid != T.cid) return error.UnexpectedConstructor;
    }
    return decodeStructBody(T, r, allocator);
}

fn decodeUnion(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    const cid = try r.takeInt(u32, .little);
    if (cid == 0x3072cfa1) { // gzip_packed
        const data = try decompressGzip(r, allocator);
        defer allocator.free(data);
        var dr = std.Io.Reader.fixed(data);
        return decodeUnion(T, &dr, allocator);
    }
    inline for (std.meta.fields(T)) |field| {
        const VT = field.type;
        const is_ptr = @typeInfo(VT) == .pointer;
        const BT = if (is_ptr) std.meta.Child(VT) else VT;
        if (@hasDecl(BT, "cid") and BT.cid == cid) {
            const body = try decodeStructBody(BT, r, allocator);
            if (is_ptr) {
                const ptr = try allocator.create(BT);
                ptr.* = body;
                return @unionInit(T, field.name, ptr);
            }
            return @unionInit(T, field.name, body);
        }
    }
    return error.UnknownConstructor;
}
