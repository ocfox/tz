const std = @import("std");
const Allocator = std.mem.Allocator;
const de = @import("deserialize.zig");

pub const serialize = @import("serialize.zig");
pub const deserialize = @import("deserialize.zig");

pub const Flags = struct {};
pub const Flags2 = struct {};

pub fn Flag(comptime bit: u5, comptime T: type) type {
    return struct {
        pub const flag_word: u1 = 0;
        pub const flag_bit = bit;
        pub const Inner = T;
        value: ?T,

        pub const none: @This() = .{ .value = null };

        pub fn some(v: T) @This() {
            return .{ .value = v };
        }
    };
}

pub fn Flag2(comptime bit: u5, comptime T: type) type {
    return struct {
        pub const flag_word: u1 = 1;
        pub const flag_bit = bit;
        pub const Inner = T;
        value: ?T,

        pub const none: @This() = .{ .value = null };

        pub fn some(v: T) @This() {
            return .{ .value = v };
        }
    };
}

pub fn isFlag(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "flag_bit") and @hasDecl(T, "Inner") and @hasDecl(T, "flag_word"),
        else => false,
    };
}

pub fn isFlags(comptime T: type) bool {
    return T == Flags;
}

pub fn isFlags2(comptime T: type) bool {
    return T == Flags2;
}

pub fn encodeAlloc(value: anytype, allocator: Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try encodeInto(value, &buf, allocator);
    return buf.toOwnedSlice(allocator);
}

/// Encode into any std.Io.Writer. No heap allocation on the encode path.
pub fn encode(value: anytype, writer: *std.Io.Writer) !void {
    try encodeWriter(@TypeOf(value), value, writer);
}

fn encodeWriter(comptime T: type, value: T, w: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .int, .comptime_int => try w.writeInt(T, value, .little),
        .float => {
            const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));
            try w.writeInt(IntT, @bitCast(value), .little);
        },
        .bool => {
            const id: u32 = if (value) 0x997275b5 else 0xbc799737;
            try w.writeInt(u32, id, .little);
        },
        .array => |arr| {
            if (arr.child != u8) @compileError("only [N]u8 arrays supported");
            try w.writeAll(&value);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child == u8 or (ptr.is_const and ptr.child == u8)) {
                    try encodeBytesWriter(value, w);
                } else {
                    try encodeVectorWriter(value, w);
                }
            },
            .one => try encodeWriter(ptr.child, value.*, w),
            else => @compileError("unsupported pointer kind"),
        },
        .@"struct" => try encodeStructWriter(T, value, w),
        .@"union" => try encodeUnionWriter(T, value, w),
        .void => {},
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn encodeBytesWriter(data: []const u8, w: *std.Io.Writer) !void {
    const len = data.len;
    const pad_zeros = [3]u8{ 0, 0, 0 };
    if (len <= 253) {
        try w.writeAll(&.{@intCast(len)});
        try w.writeAll(data);
        const total = 1 + len;
        const pad = (4 - (total % 4)) % 4;
        try w.writeAll(pad_zeros[0..pad]);
    } else {
        try w.writeAll(&.{ 254, @intCast(len & 0xff), @intCast((len >> 8) & 0xff), @intCast((len >> 16) & 0xff) });
        try w.writeAll(data);
        const total = 4 + len;
        const pad = (4 - (total % 4)) % 4;
        try w.writeAll(pad_zeros[0..pad]);
    }
}

fn encodeVectorWriter(slice: anytype, w: *std.Io.Writer) !void {
    try w.writeInt(u32, 0x1cb5c415, .little);
    try w.writeInt(u32, @intCast(slice.len), .little);
    for (slice) |item| try encodeWriter(@TypeOf(item), item, w);
}

fn encodeStructWriter(comptime T: type, value: T, w: *std.Io.Writer) !void {
    if (@hasDecl(T, "cid")) try w.writeInt(u32, T.cid, .little);
    try encodeStructBodyWriter(T, value, w);
}

fn encodeStructBodyWriter(comptime T: type, value: T, w: *std.Io.Writer) !void {
    inline for (std.meta.fields(T), 0..) |field, i| {
        const fv = @field(value, field.name);
        if (comptime isFlags(field.type) or isFlags2(field.type)) {
            const this_word: u1 = if (comptime isFlags(field.type)) 0 else 1;
            var bits: u32 = 0;
            inline for (std.meta.fields(T)[i + 1 ..]) |next| {
                if (comptime isFlags(next.type) or isFlags2(next.type)) break;
                if (comptime isFlag(next.type) and next.type.flag_word == this_word) {
                    if (@field(value, next.name).value != null) {
                        bits |= @as(u32, 1) << @as(u5, next.type.flag_bit);
                    }
                }
            }
            try w.writeInt(u32, bits, .little);
        } else if (comptime isFlag(field.type)) {
            if (fv.value) |inner| {
                if (comptime field.type.Inner != void) {
                    try encodeWriter(field.type.Inner, inner, w);
                }
            }
        } else {
            try encodeWriter(field.type, fv, w);
        }
    }
}

fn encodeUnionWriter(comptime T: type, value: T, w: *std.Io.Writer) !void {
    const tag = std.meta.activeTag(value);
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, @tagName(tag))) {
            const variant = @field(value, field.name);
            const VT = field.type;
            const is_ptr = @typeInfo(VT) == .pointer;
            const BT = if (is_ptr) std.meta.Child(VT) else VT;
            const body = if (is_ptr) variant.* else variant;
            if (@hasDecl(BT, "cid")) try w.writeInt(u32, BT.cid, .little);
            if (BT != void) try encodeStructBodyWriter(BT, body, w);
            return;
        }
    }
}

fn encodeInto(value: anytype, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) Allocator.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const start = buf.items.len;
            try buf.resize(allocator, start + @sizeOf(T));
            std.mem.writeInt(T, buf.items[start..][0..@sizeOf(T)], value, .little);
        },
        .float => {
            const start = buf.items.len;
            try buf.resize(allocator, start + @sizeOf(T));
            const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(IntT, buf.items[start..][0..@sizeOf(T)], @bitCast(value), .little);
        },
        .bool => {
            // TL bool: boolTrue = 0x997275b5, boolFalse = 0xbc799737
            const id: u32 = if (value) 0x997275b5 else 0xbc799737;
            try encodeInto(id, buf, allocator);
        },
        .array => |arr| {
            if (arr.child != u8) @compileError("only [N]u8 arrays supported");
            try buf.appendSlice(allocator, &value);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child == u8 or (ptr.is_const and ptr.child == u8)) {
                    try encodeBytes(value, buf, allocator);
                } else {
                    try encodeVector(value, buf, allocator);
                }
            },
            .one => try encodeInto(value.*, buf, allocator),
            else => @compileError("unsupported pointer kind"),
        },
        .@"struct" => try encodeStruct(T, value, buf, allocator),
        .@"union" => try encodeUnion(T, value, buf, allocator),
        .void => {},
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn encodeBytes(data: []const u8, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    const len = data.len;
    if (len <= 253) {
        try buf.append(allocator, @intCast(len));
        try buf.appendSlice(allocator, data);
        const total = 1 + len;
        const pad = (4 - (total % 4)) % 4;
        try buf.appendNTimes(allocator, 0, pad);
    } else {
        try buf.append(allocator, 254);
        try buf.append(allocator, @intCast(len & 0xff));
        try buf.append(allocator, @intCast((len >> 8) & 0xff));
        try buf.append(allocator, @intCast((len >> 16) & 0xff));
        try buf.appendSlice(allocator, data);
        const total = 4 + len;
        const pad = (4 - (total % 4)) % 4;
        try buf.appendNTimes(allocator, 0, pad);
    }
}

fn encodeVector(slice: anytype, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    try encodeInto(@as(u32, 0x1cb5c415), buf, allocator);
    try encodeInto(@as(u32, @intCast(slice.len)), buf, allocator);
    for (slice) |item| {
        try encodeInto(item, buf, allocator);
    }
}

fn encodeStruct(comptime T: type, value: T, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    if (@hasDecl(T, "cid")) {
        const old = buf.items.len;
        try buf.resize(allocator, old + 4);
        std.mem.writeInt(u32, buf.items[old..][0..4], T.cid, .little);
    }
    try encodeStructBody(T, value, buf, allocator);
}

fn encodeStructBody(comptime T: type, value: T, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    // For each flags word, compute its bits from the Flag/Flag2 fields that reference it.
    inline for (std.meta.fields(T), 0..) |field, i| {
        const fv = @field(value, field.name);
        if (comptime isFlags(field.type) or isFlags2(field.type)) {
            const this_word: u1 = if (comptime isFlags(field.type)) 0 else 1;
            var bits: u32 = 0;
            inline for (std.meta.fields(T)[i + 1 ..]) |next| {
                if (comptime isFlags(next.type) or isFlags2(next.type)) break;
                if (comptime isFlag(next.type) and next.type.flag_word == this_word) {
                    if (@field(value, next.name).value != null) {
                        bits |= @as(u32, 1) << @as(u5, next.type.flag_bit);
                    }
                }
            }
            const old = buf.items.len;
            try buf.resize(allocator, old + 4);
            std.mem.writeInt(u32, buf.items[old..][0..4], bits, .little);
        } else if (comptime isFlag(field.type)) {
            if (fv.value) |inner| {
                if (comptime field.type.Inner != void) {
                    try encodeInto(inner, buf, allocator);
                }
            }
        } else {
            try encodeInto(fv, buf, allocator);
        }
    }
}

fn encodeUnion(comptime T: type, value: T, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    const tag = std.meta.activeTag(value);
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, @tagName(tag))) {
            const variant = @field(value, field.name);
            const VT = field.type;
            // Union variants may be boxed (*Foo) for recursive types.
            const is_ptr = @typeInfo(VT) == .pointer;
            const BT = if (is_ptr) std.meta.Child(VT) else VT;
            const body = if (is_ptr) variant.* else variant;
            if (@hasDecl(BT, "cid")) {
                const old = buf.items.len;
                try buf.resize(allocator, old + 4);
                std.mem.writeInt(u32, buf.items[old..][0..4], BT.cid, .little);
            }
            if (BT != void) {
                try encodeStructBody(BT, body, buf, allocator);
            }
            return;
        }
    }
}

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

fn decodeVector(comptime Child: type, r: *std.Io.Reader, allocator: Allocator) anyerror![]Child {
    const cid = try r.takeInt(u32, .little);
    if (cid != 0x1cb5c415) return error.UnexpectedConstructor;
    const count = try r.takeInt(u32, .little);
    const slice = try allocator.alloc(Child, count);
    errdefer allocator.free(slice);
    for (slice) |*item| {
        item.* = try decode(Child, r, allocator);
    }
    return slice;
}

fn decodeStruct(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    if (@hasDecl(T, "cid")) {
        const cid = try r.takeInt(u32, .little);
        if (cid == 0x3072cfa1) { // gzip_packed
            const compressed = try de.bytes(r, allocator);
            defer allocator.free(compressed);
            var in = std.Io.Reader.fixed(compressed);
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            _ = try decomp.reader.streamRemaining(&aw.writer);
            var dr = std.Io.Reader.fixed(aw.written());
            return decodeStruct(T, &dr, allocator);
        }
        if (cid != T.cid) return error.UnexpectedConstructor;
    }
    return decodeStructBody(T, r, allocator);
}

pub fn decodeStructBody(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    // SAFETY: every field is written by the inline for loop below before result is returned
    var result: T = undefined;
    var flags_val: u32 = 0; // flags word 0
    var flags2_val: u32 = 0; // flags word 1
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

fn decodeUnion(comptime T: type, r: *std.Io.Reader, allocator: Allocator) anyerror!T {
    const cid = try r.takeInt(u32, .little);
    if (cid == 0x3072cfa1) { // gzip_packed
        const compressed = try de.bytes(r, allocator);
        defer allocator.free(compressed);
        var in = std.Io.Reader.fixed(compressed);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = try decomp.reader.streamRemaining(&aw.writer);
        const decompressed = aw.written();
        var dr = std.Io.Reader.fixed(decompressed);
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
