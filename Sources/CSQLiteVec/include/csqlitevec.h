#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H

/* Forward-declare sqlite3 as an incomplete type so Swift imports `sqlite3 *`
 * as OpaquePointer — matching the handle type used by the system SQLite3 module. */
typedef struct sqlite3 sqlite3;

/* Register sqlite-vec (the vec0 virtual table + vec_* SQL functions) on an
 * already-open connection. Returns SQLITE_OK (0) on success; on failure sets
 * *errmsg to a malloc'd message (caller frees with sqlite3_free). */
int csv_register_vec(sqlite3 *db, char **errmsg);

#endif /* CSQLITEVEC_H */
