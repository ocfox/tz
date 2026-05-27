const Storage = @This();
const std = @import("std");
const Io = std.Io;

pub const SessionData = extern struct {
    auth_key: [256]u8,
    auth_key_id: i64,
    server_salt: i64,
    dc_id: u8,
    is_home: bool = false,
    _pad: [6]u8 = .{0} ** 6,
};

/// DC IDs 1-5; stored at slot index dc_id-1.
pub const max_dc_id: u8 = 5;
const numSlots = max_dc_id;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    load: *const fn (*anyopaque, Io, dc_id: u8) anyerror!?SessionData,
    save: *const fn (*anyopaque, Io, SessionData) anyerror!void,
    loadUpdateState: *const fn (*anyopaque, Io, std.mem.Allocator) anyerror!?[]u8,
    saveUpdateState: *const fn (*anyopaque, Io, []const u8) anyerror!void,
};

pub fn load(self: Storage, io: Io, dc_id: u8) !?SessionData {
    return self.vtable.load(self.ptr, io, dc_id);
}
pub fn save(self: Storage, io: Io, data: SessionData) !void {
    return self.vtable.save(self.ptr, io, data);
}
pub fn loadUpdateState(self: Storage, io: Io, gpa: std.mem.Allocator) !?[]u8 {
    return self.vtable.loadUpdateState(self.ptr, io, gpa);
}
pub fn saveUpdateState(self: Storage, io: Io, bytes: []const u8) !void {
    return self.vtable.saveUpdateState(self.ptr, io, bytes);
}

const magic: u32 = 0x545A5331; // "TZS1"
const format_version: u16 = 1;

const Parsed = struct {
    sessions: [numSlots]?SessionData = .{null} ** numSlots,
    update_state: ?[]u8 = null,

    fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        if (self.update_state) |b| gpa.free(b);
    }
};

fn readAll(io: Io, gpa: std.mem.Allocator, path: []const u8) !Parsed {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Parsed{},
        else => return err,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.size == 0 or st.size > (1 << 20)) return Parsed{};
    const raw = try gpa.alloc(u8, @intCast(st.size));
    defer gpa.free(raw);
    const got = try file.readPositionalAll(io, raw, 0);
    if (got < 7) return Parsed{};
    var r: std.Io.Reader = .fixed(raw[0..got]);
    if (try r.takeInt(u32, .little) != magic) return Parsed{};
    if (try r.takeInt(u16, .little) != format_version) return Parsed{};
    var parsed = Parsed{};
    const count = try r.takeInt(u8, .little);
    for (0..count) |_| {
        var sd: SessionData = undefined;
        try r.readSliceAll(std.mem.asBytes(&sd));
        if (sd.dc_id >= 1 and sd.dc_id <= max_dc_id) parsed.sessions[sd.dc_id - 1] = sd;
    }
    const blob_len = try r.takeInt(u32, .little);
    if (blob_len > 0) {
        const buf = try gpa.alloc(u8, blob_len);
        errdefer gpa.free(buf);
        try r.readSliceAll(buf);
        parsed.update_state = buf;
    }
    return parsed;
}

fn writeAll(io: Io, path: []const u8, parsed: Parsed) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [16]u8 = undefined;
    var hdr: std.Io.Writer = .fixed(&buf);
    try hdr.writeInt(u32, magic, .little);
    try hdr.writeInt(u16, format_version, .little);
    var n: u8 = 0;
    for (parsed.sessions) |slot| {
        if (slot != null) n += 1;
    }
    try hdr.writeInt(u8, n, .little);
    var off: u64 = 0;
    try file.writePositionalAll(io, hdr.buffered(), off);
    off += hdr.buffered().len;
    for (parsed.sessions) |slot| {
        if (slot) |sd| {
            const bytes = std.mem.asBytes(&sd);
            try file.writePositionalAll(io, bytes, off);
            off += bytes.len;
        }
    }
    var lenbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenbuf, if (parsed.update_state) |b| @intCast(b.len) else 0, .little);
    try file.writePositionalAll(io, &lenbuf, off);
    off += lenbuf.len;
    if (parsed.update_state) |b| try file.writePositionalAll(io, b, off);
}

pub const Memory = struct {
    slots: [numSlots]?SessionData = .{null} ** numSlots,
    update_state: ?[]u8 = null,
    gpa: ?std.mem.Allocator = null,

    pub fn storage(self: *Memory) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = Storage.VTable{
        .load = Memory.load,
        .save = Memory.save,
        .loadUpdateState = Memory.loadUpdateState,
        .saveUpdateState = Memory.saveUpdateState,
    };
    fn load(ptr: *anyopaque, _: Io, dc_id: u8) anyerror!?SessionData {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        if (dc_id < 1 or dc_id > max_dc_id) return null;
        return self.slots[dc_id - 1];
    }
    fn save(ptr: *anyopaque, _: Io, data: SessionData) anyerror!void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        if (data.dc_id < 1 or data.dc_id > max_dc_id) return;
        self.slots[data.dc_id - 1] = data;
    }
    fn loadUpdateState(ptr: *anyopaque, _: Io, gpa: std.mem.Allocator) anyerror!?[]u8 {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        const b = self.update_state orelse return null;
        return try gpa.dupe(u8, b);
    }
    fn saveUpdateState(ptr: *anyopaque, _: Io, bytes: []const u8) anyerror!void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        const g = self.gpa orelse std.heap.page_allocator;
        if (self.update_state) |old| g.free(old);
        self.update_state = try g.dupe(u8, bytes);
    }
};

/// Session + update-state storage backed by a single versioned file.
/// Whole-file read-modify-write under a mutex.
pub const File = struct {
    path: []const u8,
    mu: std.Io.Mutex = .init,

    pub fn init(path: []const u8) File {
        return .{ .path = path };
    }
    pub fn storage(self: *File) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = Storage.VTable{
        .load = File.load,
        .save = File.save,
        .loadUpdateState = File.loadUpdateState,
        .saveUpdateState = File.saveUpdateState,
    };

    fn load(ptr: *anyopaque, io: Io, dc_id: u8) anyerror!?SessionData {
        const self: *File = @ptrCast(@alignCast(ptr));
        if (dc_id < 1 or dc_id > max_dc_id) return null;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var parsed = try readAll(io, std.heap.page_allocator, self.path);
        defer parsed.deinit(std.heap.page_allocator);
        const sd = parsed.sessions[dc_id - 1] orelse return null;
        if (sd.auth_key_id == 0) return null;
        return sd;
    }
    fn save(ptr: *anyopaque, io: Io, data: SessionData) anyerror!void {
        const self: *File = @ptrCast(@alignCast(ptr));
        if (data.dc_id < 1 or data.dc_id > max_dc_id) return error.InvalidDcId;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var parsed = try readAll(io, std.heap.page_allocator, self.path);
        defer parsed.deinit(std.heap.page_allocator);
        parsed.sessions[data.dc_id - 1] = data;
        try writeAll(io, self.path, parsed);
    }
    fn loadUpdateState(ptr: *anyopaque, io: Io, gpa: std.mem.Allocator) anyerror!?[]u8 {
        const self: *File = @ptrCast(@alignCast(ptr));
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var parsed = try readAll(io, gpa, self.path);
        const blob = parsed.update_state;
        parsed.update_state = null;
        return blob;
    }
    fn saveUpdateState(ptr: *anyopaque, io: Io, bytes: []const u8) anyerror!void {
        const self: *File = @ptrCast(@alignCast(ptr));
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var parsed = try readAll(io, std.heap.page_allocator, self.path);
        defer parsed.deinit(std.heap.page_allocator);
        const dup = try std.heap.page_allocator.dupe(u8, bytes);
        if (parsed.update_state) |old| std.heap.page_allocator.free(old);
        parsed.update_state = dup;
        try writeAll(io, self.path, parsed);
    }
};

test "Memory load/save roundtrip" {
    var mem = Memory{};
    const s = mem.storage();
    try std.testing.expect(try s.load(std.Io.failing, 2) == null);
    var data: SessionData = undefined;
    @memset(&data.auth_key, 0xab);
    data.auth_key_id = 12345;
    data.server_salt = -99;
    data.dc_id = 2;
    data.is_home = false;
    try s.save(std.Io.failing, data);
    const loaded = try s.load(std.Io.failing, 2);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualSlices(u8, &data.auth_key, &loaded.?.auth_key);
    try std.testing.expectEqual(data.auth_key_id, loaded.?.auth_key_id);
}

test "File load/save roundtrip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/tz_test_session.bin";
    var fs = File.init(path);
    const s = fs.storage();
    var data: SessionData = undefined;
    @memset(&data.auth_key, 0xcd);
    data.auth_key_id = 99999;
    data.server_salt = 42;
    data.dc_id = 1;
    data.is_home = false;
    try s.save(io, data);
    const loaded = (try s.load(io, 1)).?;
    try std.testing.expectEqualSlices(u8, &data.auth_key, &loaded.auth_key);
    try std.testing.expectEqual(data.dc_id, loaded.dc_id);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "File: session + update state unified roundtrip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/tz_test_unified.bin";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    var fs = File.init(path);
    const s = fs.storage();

    var data: SessionData = undefined;
    @memset(&data.auth_key, 0x7);
    data.auth_key_id = 555;
    data.server_salt = 9;
    data.dc_id = 2;
    data.is_home = true;
    try s.save(io, data);

    const blob = [_]u8{ 1, 2, 3, 4, 5 };
    try s.saveUpdateState(io, &blob);

    const loaded = (try s.load(io, 2)).?;
    try std.testing.expectEqual(@as(i64, 555), loaded.auth_key_id);
    try std.testing.expect(loaded.is_home);

    const got = (try s.loadUpdateState(io, std.testing.allocator)).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &blob, got);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "Memory: update state roundtrip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mem = Memory{};
    mem.gpa = std.testing.allocator;
    const s = mem.storage();
    try std.testing.expect((try s.loadUpdateState(io, std.testing.allocator)) == null);
    const blob = [_]u8{ 9, 8, 7 };
    try s.saveUpdateState(io, &blob);
    const got = (try s.loadUpdateState(io, std.testing.allocator)).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &blob, got);
    if (mem.update_state) |b| std.testing.allocator.free(b);
}
