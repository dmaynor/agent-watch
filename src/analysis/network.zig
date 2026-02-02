const std = @import("std");
const types = @import("../data/types.zig");

/// Network connection inventory for a PID
pub const ConnectionInventory = struct {
    total: usize = 0,
    established: usize = 0,
    listening: usize = 0,
    time_wait: usize = 0,
    other: usize = 0,
    unique_remotes: usize = 0,
};

/// Build connection inventory from a set of connections
pub fn buildInventory(conns: []const types.NetConnection) ConnectionInventory {
    var inv = ConnectionInventory{};
    inv.total = conns.len;

    for (conns) |conn| {
        if (std.mem.eql(u8, conn.state, "ESTABLISHED")) {
            inv.established += 1;
        } else if (std.mem.eql(u8, conn.state, "LISTEN")) {
            inv.listening += 1;
        } else if (std.mem.eql(u8, conn.state, "TIME_WAIT")) {
            inv.time_wait += 1;
        } else {
            inv.other += 1;
        }
    }

    return inv;
}

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "buildInventory: empty input" {
    const conns: []const types.NetConnection = &.{};
    const inv = buildInventory(conns);
    try testing.expectEqual(@as(usize, 0), inv.total);
    try testing.expectEqual(@as(usize, 0), inv.established);
}

test "buildInventory: counts ESTABLISHED" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "ESTABLISHED" }),
        helpers.makeNetConnection(.{ .state = "ESTABLISHED" }),
    };
    const inv = buildInventory(&conns);
    try testing.expectEqual(@as(usize, 2), inv.total);
    try testing.expectEqual(@as(usize, 2), inv.established);
}

test "buildInventory: counts all states" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "ESTABLISHED" }),
        helpers.makeNetConnection(.{ .state = "LISTEN" }),
        helpers.makeNetConnection(.{ .state = "TIME_WAIT" }),
        helpers.makeNetConnection(.{ .state = "SYN_SENT" }),
    };
    const inv = buildInventory(&conns);
    try testing.expectEqual(@as(usize, 4), inv.total);
    try testing.expectEqual(@as(usize, 1), inv.established);
    try testing.expectEqual(@as(usize, 1), inv.listening);
    try testing.expectEqual(@as(usize, 1), inv.time_wait);
    try testing.expectEqual(@as(usize, 1), inv.other);
}
