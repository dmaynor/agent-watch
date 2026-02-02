#include "sqlite3.h"

/* Wrapper to call sqlite3_bind_text with SQLITE_TRANSIENT, since
   Zig 0.15 cannot cast the sentinel pointer value (-1) to a function pointer. */
int aw_sqlite3_bind_text_transient(sqlite3_stmt *stmt, int col,
                                    const char *text, int len) {
    return sqlite3_bind_text(stmt, col, text, len, SQLITE_TRANSIENT);
}
