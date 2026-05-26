const std = @import("std");
const Io = std.Io;

pub const SessionData = extern struct {
    auth_key: [256]u8,
    auth_key_id: i64,
    server_salt: i64,
    dc_id: u8,
    home_dc: u8 = 0,
    _pad: [6]u8 = .{0} ** 6,
};

/// DC IDs 1-5; stored at slot index dc_id-1.
pub const max_dc_id: u8 = 5;
const num_slots = max_dc_id;

pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Io, dc_id: u8) anyerror!?SessionData,
        save: *const fn (*anyopaque, Io, SessionData) anyerror!void,
    };

    pub fn load(self: Storage, io: Io, dc_id: u8) !?SessionData {
        return self.vtable.load(self.ptr, io, dc_id);
    }
    pub fn save(self: Storage, io: Io, data: SessionData) !void {
        return self.vtable.save(self.ptr, io, data);
    }
};

pub const MemoryStorage = struct {
    slots: [num_slots]?SessionData = .{null} ** num_slots,

    pub fn storage(self: *MemoryStorage) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = Storage.VTable{ .load = load, .save = save };
    fn load(ptr: *anyopaque, _: Io, dc_id: u8) anyerror!?SessionData {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (dc_id < 1 or dc_id > max_dc_id) return null;
        return self.slots[dc_id - 1];
    }
    fn save(ptr: *anyopaque, _: Io, data: SessionData) anyerror!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (data.dc_id < 1 or data.dc_id > max_dc_id) return;
        self.slots[data.dc_id - 1] = data;
    }
};

/// Session storage backed by a single file with fixed 280-byte segments,
/// one per DC ID (segment at offset (dc_id-1) * @sizeOf(SessionData)).
pub const FileStorage = struct {
    path: []const u8,

    pub fn init(path: []const u8) FileStorage {
        return .{ .path = path };
    }
    pub fn storage(self: *FileStorage) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = Storage.VTable{ .load = load, .save = save };
    fn load(ptr: *anyopaque, io: Io, dc_id: u8) anyerror!?SessionData {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        if (dc_id < 1 or dc_id > max_dc_id) return null;
        const file = Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        // SAFETY: immediately overwritten by readPositionalAll
        var data: SessionData = undefined;
        const offset: u64 = @as(u64, dc_id - 1) * @sizeOf(SessionData);
        const n = try file.readPositionalAll(io, std.mem.asBytes(&data), offset);
        if (n != @sizeOf(SessionData)) return null;
        if (data.auth_key_id == 0) return null;
        return data;
    }
    fn save(ptr: *anyopaque, io: Io, data: SessionData) anyerror!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        if (data.dc_id < 1 or data.dc_id > max_dc_id) return error.InvalidDcId;
        // truncate=false: create if not exists, update slot in place if exists.
        const file = try Io.Dir.cwd().createFile(io, self.path, .{ .truncate = false });
        defer file.close(io);
        const offset: u64 = @as(u64, data.dc_id - 1) * @sizeOf(SessionData);
        try file.writePositionalAll(io, std.mem.asBytes(&data), offset);
    }
};

test "MemoryStorage load/save roundtrip" {
    var mem = MemoryStorage{};
    const s = mem.storage();
    try std.testing.expect(try s.load(std.Io.failing, 2) == null);
    var data: SessionData = undefined;
    @memset(&data.auth_key, 0xab);
    data.auth_key_id = 12345;
    data.server_salt = -99;
    data.dc_id = 2;
    data.home_dc = 0;
    try s.save(std.Io.failing, data);
    const loaded = try s.load(std.Io.failing, 2);
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
    data.home_dc = 0;
    try s.save(io, data);
    const loaded = (try s.load(io, 1)).?;
    try std.testing.expectEqualSlices(u8, &data.auth_key, &loaded.auth_key);
    try std.testing.expectEqual(data.dc_id, loaded.dc_id);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}
