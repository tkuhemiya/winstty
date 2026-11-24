//! A client for the Rex server of this machine.
//!
//! This follows what the server documents at `/llms.txt`. It's the only thing
//! this connects to, over a named pipe, and nothing leaves the machine.
pub const Client = @import("Client.zig");
pub const Pipe = @import("Pipe.zig");
pub const Stream = @import("Stream.zig");
pub const launch = @import("launch.zig");
pub const status = @import("status.zig");
pub const view = @import("view.zig");
pub const websocket = @import("websocket.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
