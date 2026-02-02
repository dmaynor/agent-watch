const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const schema = @import("schema.zig");

pub const SqliteError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ResetFailed,
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &handle);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return SqliteError.OpenFailed;
        }
        var db = Db{ .handle = handle.? };
        try db.exec("PRAGMA journal_mode=WAL;");
        try db.exec("PRAGMA synchronous=NORMAL;");
        try db.exec("PRAGMA busy_timeout=5000;");
        try db.initSchema();
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.log.err("SQLite exec error: {s}", .{msg});
                c.sqlite3_free(msg);
            }
            return SqliteError.ExecFailed;
        }
    }

    pub fn execMulti(self: *Db, sql: []const u8) !void {
        // Execute multiple semicolon-separated statements
        var remaining = sql;
        while (remaining.len > 0) {
            // Skip whitespace
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\n' or remaining[0] == '\r' or remaining[0] == '\t')) {
                remaining = remaining[1..];
            }
            if (remaining.len == 0) break;

            var stmt: ?*c.sqlite3_stmt = null;
            var tail: [*c]const u8 = null;
            const rc = c.sqlite3_prepare_v2(
                self.handle,
                remaining.ptr,
                @intCast(remaining.len),
                &stmt,
                &tail,
            );
            if (rc != c.SQLITE_OK) {
                std.log.err("SQLite prepare error: {s}", .{c.sqlite3_errmsg(self.handle)});
                return SqliteError.PrepareFailed;
            }

            if (stmt) |s| {
                defer _ = c.sqlite3_finalize(s);
                const step_rc = c.sqlite3_step(s);
                if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                    std.log.err("SQLite step error: {s}", .{c.sqlite3_errmsg(self.handle)});
                    return SqliteError.StepFailed;
                }
            }

            if (tail) |t| {
                const offset = @intFromPtr(t) - @intFromPtr(remaining.ptr);
                if (offset >= remaining.len) break;
                remaining = remaining[offset..];
            } else {
                break;
            }
        }
    }

    fn initSchema(self: *Db) !void {
        try self.execMulti(schema.create_tables);
        try self.execMulti(schema.create_indexes);
    }

    pub fn prepare(self: *Db, sql: [*:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            std.log.err("SQLite prepare error: {s}", .{c.sqlite3_errmsg(self.handle)});
            return SqliteError.PrepareFailed;
        }
        return Statement{ .handle = stmt.?, .db = self.handle };
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Statement) !void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return SqliteError.ResetFailed;
    }

    pub fn clearBindings(self: *Statement) void {
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn bindI64(self: *Statement, col: c_int, val: i64) !void {
        if (c.sqlite3_bind_int64(self.handle, col, val) != c.SQLITE_OK)
            return SqliteError.BindFailed;
    }

    pub fn bindI32(self: *Statement, col: c_int, val: i32) !void {
        if (c.sqlite3_bind_int(self.handle, col, val) != c.SQLITE_OK)
            return SqliteError.BindFailed;
    }

    pub fn bindF64(self: *Statement, col: c_int, val: f64) !void {
        if (c.sqlite3_bind_double(self.handle, col, val) != c.SQLITE_OK)
            return SqliteError.BindFailed;
    }

    pub fn bindText(self: *Statement, col: c_int, val: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, col, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK)
            return SqliteError.BindFailed;
    }

    pub fn step(self: *Statement) !StepResult {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_DONE => .done,
            c.SQLITE_ROW => .row,
            else => {
                std.log.err("SQLite step error: {s}", .{c.sqlite3_errmsg(self.db)});
                return SqliteError.StepFailed;
            },
        };
    }

    pub fn columnI64(self: *Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn columnI32(self: *Statement, col: c_int) i32 {
        return c.sqlite3_column_int(self.handle, col);
    }

    pub fn columnF64(self: *Statement, col: c_int) f64 {
        return c.sqlite3_column_double(self.handle, col);
    }

    pub fn columnText(self: *Statement, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        return ptr[0..len];
    }

    pub const StepResult = enum {
        done,
        row,
    };
};
