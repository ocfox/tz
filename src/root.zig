const std = @import("std");
const connector = @import("connector.zig");
const client = @import("client.zig");

pub const types = @import("types");
pub const functions = @import("functions");

pub const Client = client.Client;
pub const ClientOptions = client.ClientOptions;
pub const Context = client.Context;
pub const handler = client.handler;

pub const storage = @import("session/storage.zig");

pub const DC = connector.DC;
pub const default_dcs = connector.default_dcs;

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
