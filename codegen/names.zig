const std = @import("std");

pub fn typeName(tl_type: []const u8, buf: []u8) []u8 {
    var out: usize = 0;
    var cap = true;
    for (tl_type) |c| {
        if (c == '.' or c == '_') {
            cap = true;
            continue;
        }
        buf[out] = if (cap) std.ascii.toUpper(c) else c;
        cap = false;
        out += 1;
    }
    return buf[0..out];
}

pub fn fieldName(tl_name: []const u8, buf: []u8) []u8 {
    const keywords = [_][]const u8{ "type", "error", "align", "test" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, tl_name, kw)) {
            return std.fmt.bufPrint(buf, "@\"{s}\"", .{kw}) catch @panic("buf too small");
        }
    }
    @memcpy(buf[0..tl_name.len], tl_name);
    return buf[0..tl_name.len];
}
