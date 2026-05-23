const codec_mod = @import("codec");
pub const tl = struct {
    pub const codec = codec_mod;
    pub const serialize = codec_mod.serialize;
    pub const deserialize = codec_mod.deserialize;
};
pub const types = @import("types");
pub const functions = @import("functions");
pub const crypto = struct {
    pub const sha = @import("crypto/sha.zig");
    pub const aes_ige = @import("crypto/aes_ige.zig");
    pub const rsa = @import("crypto/rsa.zig");
    pub const dh = @import("crypto/dh.zig");
};
pub const transport = struct {
    pub const tcp = @import("transport/tcp.zig");
    pub const ws = @import("transport/ws.zig");
};
pub const session = struct {
    pub const storage = @import("session/storage.zig");
    pub const message = @import("session/message.zig");
    pub const auth_key = @import("session/auth_key.zig");
    pub const auth = @import("session/auth.zig");
};
pub const conn = @import("conn.zig");
pub const Conn = conn.Conn;
pub const connect = conn.connect;
pub const DC = conn.DC;
pub const default_dcs = conn.default_dcs;
pub const FileStorage = @import("session/storage.zig").FileStorage;
pub const MemoryStorage = @import("session/storage.zig").MemoryStorage;
pub const UpdateHandler = conn.UpdateHandler;
pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").ClientOptions;
pub const Dispatcher = @import("dispatcher.zig").Dispatcher;
pub const Entities = @import("dispatcher.zig").Entities;
pub const message = @import("message/sender.zig");
