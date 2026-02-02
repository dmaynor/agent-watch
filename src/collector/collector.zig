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

        var result = CollectionResult{};

        // Discover agent processes
        const agents = scanner.scanForAgents(self.alloc, self.config.match_pattern) catch |err| {
            std.log.warn("Scanner error: {}", .{err});
            return result;
        };
        defer scanner.freeDiscovered(self.alloc, agents);

        result.agents_found = agents.len;

        if (agents.len == 0) return result;

        // Begin transaction for batch insert
        self.writer.beginTransaction() catch {};
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

            // Collect process status
            if (proc_status.collectStatus(agent.pid, now)) |status| {
                self.writer.writeStatus(status) catch {};
                result.status_written += 1;
            } else |_| {}

            // Collect FDs
            if (fd_info.collectFds(self.alloc, agent.pid, now)) |fds| {
                defer self.alloc.free(fds);
                for (fds) |fd| {
                    self.writer.writeFd(fd) catch {};
                    result.fds_written += 1;
                }
            } else |_| {}

            // Collect network connections
            if (net_info.collectConnections(self.alloc, agent.pid, now)) |conns| {
                defer self.alloc.free(conns);
                for (conns) |conn| {
                    self.writer.writeNetConnection(conn) catch {};
                    result.conns_written += 1;
                }
            } else |_| {}
        }

        self.writer.commitTransaction() catch {};

        return result;
    }

    pub const CollectionResult = struct {
        agents_found: usize = 0,
        samples_written: usize = 0,
        status_written: usize = 0,
        fds_written: usize = 0,
        conns_written: usize = 0,
    };
};
