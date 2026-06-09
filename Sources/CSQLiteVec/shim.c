#include "csqlitevec.h"

/* Provided by sqlite-vec.c (compiled with -DSQLITE_CORE). The third argument is
 * a const sqlite3_api_routines* which is unused under SQLITE_CORE; we pass NULL. */
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const void *pApi);

int csv_register_vec(sqlite3 *db, char **errmsg) {
    return sqlite3_vec_init(db, errmsg, 0);
}
