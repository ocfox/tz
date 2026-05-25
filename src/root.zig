const std = @import("std");
const connector_mod = @import("connector.zig");
const client_mod = @import("client.zig");

pub const types = @import("types");
pub const functions = @import("functions");

pub const Client = client_mod.Client;
pub const ClientOptions = client_mod.ClientOptions;
pub const Context = client_mod.Context;
pub const handler = client_mod.handler;

pub const FileStorage = @import("session/storage.zig").FileStorage;
pub const MemoryStorage = @import("session/storage.zig").MemoryStorage;

pub const DC = connector_mod.DC;
pub const default_dcs = connector_mod.default_dcs;

pub const helpers = @import("helpers/mod.zig");

pub const crypto = struct {
    pub const srp = @import("crypto/srp.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("crypto/sha.zig");
    _ = @import("crypto/rsa.zig");
    _ = @import("crypto/dh.zig");
    _ = @import("crypto/aes_ige.zig");
    _ = @import("session/message.zig");
}
