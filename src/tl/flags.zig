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
