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
