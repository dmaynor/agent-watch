const std = @import("std");
const types = @import("../data/types.zig");
const scanner = @import("scanner.zig");
const process_info = @import("process_info.zig");
const proc_status = @import("proc_status.zig");
const fd_info = @import("fd_info.zig");
const net_info = @import("net_info.zig");
const db_mod = @import("../store/db.zig");
const writer_mod = @import("../store/writer.zig");
const config_mod = @import("../config.zig");
const engine_mod = @import("../analysis/engine.zig");
const security = @import("../analysis/security.zig");

const Allocator = std.mem.Allocator;

pub const Collector = struct {
    alloc: Allocator,
    writer: writer_mod.Writer,
    config: config_mod.Config,
    tick_count: u64 = 0,

    pub fn init(alloc: Allocator, db: *db_mod.Db, config: config_mod.Config) !Collector {
        return .{
            .alloc = alloc,
            .writer = try writer_mod.Writer.init(db),
            .config = config,
        };
    }

    pub fn deinit(self: *Collector) void {
        self.writer.deinit();
    }

    /// Run one collection tick: scan, collect, store
    pub fn tick(self: *Collector) !CollectionResult {
        const now = std.time.timestamp();
        self.tick_count += 1;

        var result = CollectionResult{
            .timestamp = now,
        };

        // Discover agent processes
        const agents = scanner.scanForAgents(self.alloc, self.config.match_pattern) catch |err| {
            std.log.warn("Scanner error: {}", .{err});
            return result;
        };
        defer scanner.freeDiscovered(self.alloc, agents);

        result.agents_found = agents.len;

        if (agents.len == 0) return result;

        // Begin transaction for batch insert
        self.writer.beginTransaction() catch |err| {
            std.log.warn("Failed to begin transaction: {}", .{err});
            return result;
        };
        errdefer self.writer.rollbackTransaction() catch {};

        const user = std.posix.getenv("USER") orelse "unknown";

        for (agents) |agent| {
            // Upsert agent record
            self.writer.upsertAgent(agent.pid, agent.comm, agent.cmdline, now) catch |err| {
                std.log.warn("Failed to upsert agent pid={d}: {}", .{ agent.pid, err });
                continue;
            };

            // Collect process sample
            const sample = process_info.collectSample(agent.pid, agent.comm, agent.cmdline, user, now) catch |err| {
                std.log.warn("Failed to collect sample pid={d}: {}", .{ agent.pid, err });
                continue;
            };
            self.writer.writeSample(sample) catch |err| {
                std.log.warn("Failed to write sample pid={d}: {}", .{ agent.pid, err });
            };
            result.samples_written += 1;
            // Dupe strings that will outlive the scanner's agent list
            var owned_sample = sample;
            owned_sample.comm = self.alloc.dupe(u8, sample.comm) catch continue;
            owned_sample.args = self.alloc.dupe(u8, sample.args) catch {
                self.alloc.free(owned_sample.comm);
                continue;
            };
            owned_sample.user = self.alloc.dupe(u8, sample.user) catch {
                self.alloc.free(owned_sample.comm);
                self.alloc.free(owned_sample.args);
                continue;
            };
            owned_sample.stat = self.alloc.dupe(u8, sample.stat) catch {
                self.alloc.free(owned_sample.comm);
                self.alloc.free(owned_sample.args);
                self.alloc.free(owned_sample.user);
                continue;
            };
            result.samples.append(self.alloc, owned_sample) catch {
                self.alloc.free(owned_sample.comm);
                self.alloc.free(owned_sample.args);
                self.alloc.free(owned_sample.user);
                self.alloc.free(owned_sample.stat);
            };

            // Collect process status
            if (proc_status.collectStatus(agent.pid, now)) |status| {
                self.writer.writeStatus(status) catch {};
                result.status_written += 1;
                result.statuses.append(self.alloc, status) catch {};
            } else |_| {}

            // Collect FDs + security audit
            var fd_count: usize = 0;
            if (fd_info.collectFds(self.alloc, agent.pid, now)) |fds| {
                defer types.FdRecord.freeSlice(self.alloc, fds);
                fd_count = fds.len;
                for (fds) |fd| {
                    self.writer.writeFd(fd) catch {};
                    result.fds_written += 1;
                }
                // Security audit on FDs
                const fd_findings = security.auditFds(fds);
                for (fd_findings) |finding_opt| {
                    const finding = finding_opt orelse break;
                    self.writer.writeAlert(.{
                        .ts = now,
                        .pid = agent.pid,
                        .severity = finding.severity,
                        .category = finding.category,
                        .message = finding.message,
                        .value = 0,
                        .threshold = 0,
                    }) catch {};
                }
            } else |_| {}
            result.fd_counts.append(self.alloc, .{ .pid = agent.pid, .count = fd_count }) catch {};

            // Collect network connections + security audit
            var conn_count: usize = 0;
            if (net_info.collectConnections(self.alloc, agent.pid, now)) |conns| {
                defer types.NetConnection.freeSliceNoState(self.alloc, conns);
                conn_count = conns.len;
                for (conns) |conn| {
                    self.writer.writeNetConnection(conn) catch {};
                    result.conns_written += 1;
                }
                // Security audit on connections
                const conn_findings = security.auditConnections(conns);
                for (conn_findings) |finding_opt| {
                    const finding = finding_opt orelse break;
                    self.writer.writeAlert(.{
                        .ts = now,
                        .pid = agent.pid,
                        .severity = finding.severity,
                        .category = finding.category,
                        .message = finding.message,
                        .value = 0,
                        .threshold = 0,
                    }) catch {};
                }
            } else |_| {}
            result.conn_counts.append(self.alloc, .{ .pid = agent.pid, .count = conn_count }) catch {};
        }

        self.writer.commitTransaction() catch |err| {
            std.log.warn("Failed to commit transaction: {}", .{err});
            self.writer.rollbackTransaction() catch {};
        };

        return result;
    }

    pub const CollectionResult = struct {
        agents_found: usize = 0,
        samples_written: usize = 0,
        status_written: usize = 0,
        fds_written: usize = 0,
        conns_written: usize = 0,
        timestamp: i64 = 0,
        // Accumulated data for analysis engine
        samples: std.ArrayList(types.ProcessSample) = .empty,
        statuses: std.ArrayList(types.StatusRecord) = .empty,
        fd_counts: std.ArrayList(engine_mod.FdCount) = .empty,
        conn_counts: std.ArrayList(engine_mod.ConnCount) = .empty,

        pub fn deinit(self: *CollectionResult, alloc: Allocator) void {
            for (self.samples.items) |s| {
                alloc.free(s.comm);
                alloc.free(s.args);
                alloc.free(s.user);
                alloc.free(s.stat);
            }
            self.samples.deinit(alloc);
            self.statuses.deinit(alloc);
            self.fd_counts.deinit(alloc);
            self.conn_counts.deinit(alloc);
        }
    };
};
