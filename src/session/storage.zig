const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const SessionData = extern struct {
    auth_key: [256]u8,
    auth_key_id: i64,
    server_salt: i64,
    dc_id: u8,
    _pad: [7]u8 = .{0} ** 7,
};

pub const SessionStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Io, Allocator, dc_id: u8) anyerror!?SessionData,
        save: *const fn (*anyopaque, Io, SessionData) anyerror!void,
    };

    pub fn load(self: SessionStorage, io: Io, allocator: Allocator, dc_id: u8) !?SessionData {
        return self.vtable.load(self.ptr, io, allocator, dc_id);
    }
    pub fn save(self: SessionStorage, io: Io, data: SessionData) !void {
        return self.vtable.save(self.ptr, io, data);
    }
};

pub const MemoryStorage = struct {
    slots: [6]?SessionData = .{null} ** 6,

    pub fn storage(self: *MemoryStorage) SessionStorage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = SessionStorage.VTable{ .load = load, .save = save };
    fn load(ptr: *anyopaque, _: Io, _: Allocator, dc_id: u8) anyerror!?SessionData {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (dc_id >= self.slots.len) return null;
        return self.slots[dc_id];
    }
    fn save(ptr: *anyopaque, _: Io, data: SessionData) anyerror!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (data.dc_id < self.slots.len) self.slots[data.dc_id] = data;
    }
};

/// Session storage backed by a single file with fixed 280-byte segments,
/// one per DC ID (segment at offset dc_id * @sizeOf(SessionData)).
pub const FileStorage = struct {
    path: []const u8,

    pub fn init(path: []const u8) FileStorage {
        return .{ .path = path };
    }
    pub fn storage(self: *FileStorage) SessionStorage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = SessionStorage.VTable{ .load = load, .save = save };
    fn load(ptr: *anyopaque, io: Io, _: Allocator, dc_id: u8) anyerror!?SessionData {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        const file = Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        // SAFETY: immediately overwritten by readPositionalAll
        var data: SessionData = undefined;
        const offset: u64 = @as(u64, dc_id) * @sizeOf(SessionData);
        const n = try file.readPositionalAll(io, std.mem.asBytes(&data), offset);
        if (n != @sizeOf(SessionData)) return null;
        if (data.auth_key_id == 0) return null;
        return data;
    }
    fn save(ptr: *anyopaque, io: Io, data: SessionData) anyerror!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        // truncate=false: create if not exists, update slot in place if exists.
        const file = try Io.Dir.cwd().createFile(io, self.path, .{ .truncate = false });
        defer file.close(io);
        const offset: u64 = @as(u64, data.dc_id) * @sizeOf(SessionData);
        try file.writePositionalAll(io, std.mem.asBytes(&data), offset);
    }
};

test "MemoryStorage load/save roundtrip" {
    var mem = MemoryStorage{};
    const s = mem.storage();
    try std.testing.expect(try s.load(std.Io.failing, std.testing.allocator, 2) == null);
    var data: SessionData = undefined;
    @memset(&data.auth_key, 0xab);
    data.auth_key_id = 12345;
    data.server_salt = -99;
    data.dc_id = 2;
    try s.save(std.Io.failing, data);
    const loaded = try s.load(std.Io.failing, std.testing.allocator, 2);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualSlices(u8, &data.auth_key, &loaded.?.auth_key);
    try std.testing.expectEqual(data.auth_key_id, loaded.?.auth_key_id);
}

test "FileStorage load/save roundtrip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/tz_test_session.bin";
    var fs_store = FileStorage.init(path);
    const s = fs_store.storage();
    var data: SessionData = undefined;
    @memset(&data.auth_key, 0xcd);
    data.auth_key_id = 99999;
    data.server_salt = 42;
    data.dc_id = 1;
    try s.save(io, data);
    const loaded = (try s.load(io, std.testing.allocator, 1)).?;
    try std.testing.expectEqualSlices(u8, &data.auth_key, &loaded.auth_key);
    try std.testing.expectEqual(data.dc_id, loaded.dc_id);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}
