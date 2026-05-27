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

/// A bare TL vector (lowercase `vector<...>`): serialized as an i32 count followed
/// by bare elements, with no 0x1cb5c415 vector id. When the element is a constructor
/// type its body is written/read bare (no per-element constructor id). Used by the
/// MTProto service layer, e.g. future_salts.salts.
pub fn BareVector(comptime T: type) type {
    return struct {
        items: []const T,
        pub const tl_bare_vector = true;
        pub const Child = T;
    };
}

pub fn isBareVector(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "tl_bare_vector"),
        else => false,
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
