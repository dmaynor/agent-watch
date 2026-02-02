const std = @import("std");
const types = @import("../data/types.zig");

pub const SecurityFinding = struct {
    severity: types.Alert.Severity,
    category: []const u8,
    message: []const u8,
    detail: []const u8,
};

/// Sensitive path patterns that indicate credential access
const sensitive_paths = [_][]const u8{
    ".ssh/",
    ".aws/",
    ".env",
    "keyring",
    ".gnupg/",
    ".config/gcloud/",
    "credentials",
    ".npmrc",
    ".pypirc",
    "id_rsa",
    "id_ed25519",
    ".kube/config",
};

/// Allowed path prefixes (normal for agent processes)
const allowed_prefixes = [_][]const u8{
    "/proc/",
    "/dev/",
    "/tmp/",
    "/usr/",
    "/lib/",
    "/etc/ld.so",
    "/etc/resolv.conf",
    "/etc/hosts",
    "/etc/ssl/",
    "/etc/ca-certificates/",
    "pipe:",
    "socket:",
    "anon_inode:",
};

/// Audit file descriptors for security concerns
pub fn auditFds(fds: []const types.FdRecord) [16]?SecurityFinding {
    var findings: [16]?SecurityFinding = .{null} ** 16;
    var idx: usize = 0;

    for (fds) |fd| {
        if (idx >= findings.len) break;

        // Check for credential access
        for (sensitive_paths) |pattern| {
            if (containsPath(fd.path, pattern)) {
                findings[idx] = .{
                    .severity = .warning,
                    .category = "security:credential_access",
                    .message = "Agent accessing sensitive file",
                    .detail = fd.path,
                };
                idx += 1;
                break;
            }
        }
    }

    return findings;
}

/// Audit network connections for security concerns
pub fn auditConnections(conns: []const types.NetConnection) [16]?SecurityFinding {
    var findings: [16]?SecurityFinding = .{null} ** 16;
    var idx: usize = 0;

    for (conns) |conn| {
        if (idx >= findings.len) break;

        // Check for listening ports
        if (std.mem.eql(u8, conn.state, "LISTEN")) {
            findings[idx] = .{
                .severity = if (conn.local_port < 1024) .warning else .info,
                .category = "security:listening_port",
                .message = "Agent listening on port",
                .detail = conn.state,
            };
            idx += 1;
            if (idx >= findings.len) break;
        }

        // Check for connections to non-standard remote ports
        if (conn.remote_port != 0 and conn.remote_port != 80 and conn.remote_port != 443 and
            conn.remote_port != 8080 and conn.remote_port != 8443 and conn.remote_port != 53)
        {
            if (std.mem.eql(u8, conn.state, "ESTABLISHED")) {
                findings[idx] = .{
                    .severity = .info,
                    .category = "security:unexpected_network",
                    .message = "Connection to non-standard port",
                    .detail = conn.state,
                };
                idx += 1;
                if (idx >= findings.len) break;
            }
        }
    }

    return findings;
}

fn containsPath(path: []const u8, pattern: []const u8) bool {
    return std.mem.indexOf(u8, path, pattern) != null;
}

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

fn countSecurityFindings(results: [16]?SecurityFinding) usize {
    var count: usize = 0;
    for (results) |r| {
        if (r != null) count += 1;
    }
    return count;
}

test "auditFds: detects .ssh access" {
    const fds = [_]types.FdRecord{
        helpers.makeFdRecord(.{ .path = "/home/user/.ssh/id_rsa" }),
    };
    const findings = auditFds(&fds);
    try testing.expectEqual(@as(usize, 1), countSecurityFindings(findings));
    try testing.expectEqualStrings("security:credential_access", findings[0].?.category);
}

test "auditFds: detects .aws access" {
    const fds = [_]types.FdRecord{
        helpers.makeFdRecord(.{ .path = "/home/user/.aws/credentials" }),
    };
    const findings = auditFds(&fds);
    try testing.expect(countSecurityFindings(findings) >= 1);
}

test "auditFds: normal path no findings" {
    const fds = [_]types.FdRecord{
        helpers.makeFdRecord(.{ .path = "/usr/lib/libc.so.6" }),
        helpers.makeFdRecord(.{ .path = "/tmp/data.txt" }),
    };
    const findings = auditFds(&fds);
    try testing.expectEqual(@as(usize, 0), countSecurityFindings(findings));
}

test "auditFds: empty input" {
    const fds: []const types.FdRecord = &.{};
    const findings = auditFds(fds);
    try testing.expectEqual(@as(usize, 0), countSecurityFindings(findings));
}

test "auditConnections: listening port detected" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "LISTEN", .local_port = 8080 }),
    };
    const findings = auditConnections(&conns);
    try testing.expect(countSecurityFindings(findings) >= 1);
    try testing.expectEqualStrings("security:listening_port", findings[0].?.category);
}

test "auditConnections: privileged port is warning" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "LISTEN", .local_port = 80 }),
    };
    const findings = auditConnections(&conns);
    try testing.expect(countSecurityFindings(findings) >= 1);
    try testing.expectEqual(types.Alert.Severity.warning, findings[0].?.severity);
}

test "auditConnections: non-standard port connection" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "ESTABLISHED", .remote_port = 9999 }),
    };
    const findings = auditConnections(&conns);
    try testing.expect(countSecurityFindings(findings) >= 1);
}

test "auditConnections: standard port no unexpected finding" {
    const conns = [_]types.NetConnection{
        helpers.makeNetConnection(.{ .state = "ESTABLISHED", .remote_port = 443 }),
    };
    const findings = auditConnections(&conns);
    try testing.expectEqual(@as(usize, 0), countSecurityFindings(findings));
}
