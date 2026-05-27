const std = @import("std");
const Connector = @import("Connector.zig");
const client = @import("client.zig");

pub const types = @import("types");
pub const functions = @import("functions");

pub const Client = client.Client;
pub const ClientOptions = client.ClientOptions;
pub const Context = client.Context;
pub const handler = client.handler;

pub const Storage = @import("Storage.zig");

pub const DC = Connector.DC;
pub const default_dcs = Connector.default_dcs;

pub const helpers = @import("helpers.zig");

pub const MessageBox = @import("updates/MessageBox.zig");
pub const PeerCache = @import("updates/PeerCache.zig");

pub const crypto = @import("crypto.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("crypto/sha.zig");
    _ = @import("crypto/rsa.zig");
    _ = @import("crypto/dh.zig");
    _ = @import("crypto/aes_ige.zig");
    _ = @import("mtproto/Session.zig");
    _ = @import("updates/MessageBox.zig");
    _ = @import("updates/PeerCache.zig");
}
