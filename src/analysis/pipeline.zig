const std = @import("std");

/// Pipeline phase detection: idle, active, burst
pub const Phase = enum {
    idle,
    active,
    burst,

    pub fn toString(self: Phase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .active => "active",
            .burst => "burst",
        };
    }
};

/// Detect phase from CPU usage and process state
pub fn detectPhase(cpu: f64, state: []const u8) Phase {
    // Burst: high CPU or running state
    if (cpu > 80.0) return .burst;
    if (state.len > 0 and state[0] == 'R') {
        if (cpu > 20.0) return .burst;
        return .active;
    }
    // Idle: sleeping with negligible CPU
    if (cpu < 1.0) return .idle;
    // Active: moderate CPU
    return .active;
}

const testing = std.testing;

test "detectPhase: high CPU is burst" {
    try testing.expectEqual(Phase.burst, detectPhase(90.0, "S"));
}

test "detectPhase: running with moderate CPU is burst" {
    try testing.expectEqual(Phase.burst, detectPhase(30.0, "R"));
}

test "detectPhase: running with low CPU is active" {
    try testing.expectEqual(Phase.active, detectPhase(5.0, "R"));
}

test "detectPhase: sleeping with low CPU is idle" {
    try testing.expectEqual(Phase.idle, detectPhase(0.5, "S"));
}

test "detectPhase: moderate CPU sleeping is active" {
    try testing.expectEqual(Phase.active, detectPhase(20.0, "S"));
}

test "Phase toString roundtrip" {
    try testing.expectEqualStrings("idle", Phase.idle.toString());
    try testing.expectEqualStrings("active", Phase.active.toString());
    try testing.expectEqualStrings("burst", Phase.burst.toString());
}
