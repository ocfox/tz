const connector_mod = @import("connector.zig");
const client_mod = @import("client.zig");
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
    pub const srp = @import("crypto/srp.zig");
};
pub const transport = struct {
    pub const tcp = @import("transport/tcp.zig");
    pub const ws = @import("transport/ws.zig");
};
pub const session = struct {
    pub const storage = @import("session/storage.zig");
    pub const message = @import("session/message.zig");
    pub const auth_key = @import("session/auth_key.zig");
};
pub const mtproto = @import("mtproto.zig");
pub const connector = connector_mod;
pub const Connector = connector_mod.Connector;
pub const DC = connector_mod.DC;
pub const default_dcs = connector_mod.default_dcs;
pub const FileStorage = @import("session/storage.zig").FileStorage;
pub const MemoryStorage = @import("session/storage.zig").MemoryStorage;
pub const Client = client_mod.Client;
pub const ClientOptions = client_mod.ClientOptions;
pub const Context = client_mod.Context;
pub const Entities = client_mod.Entities;
pub const handler = client_mod.handler;
pub const nextRandomId = client_mod.nextRandomId;
pub const helpers = @import("helpers.zig");
pub const upload = @import("upload.zig").upload;
pub const UploadOptions = @import("upload.zig").UploadOptions;
pub const download = @import("download.zig").download;
pub const documentLocation = @import("download.zig").documentLocation;
pub const photoLocation = @import("download.zig").photoLocation;
