// =============================================================================
// Recursive directory walk shim
// =============================================================================
//
// Encapsulates the platform-fragile `dirent` / `stat` struct layouts and the
// recursive crawl ENTIRELY in C, so the Mojo side (`LocalFs.list`) never does
// raw struct-offset arithmetic or pointer walking (no UnsafePointer arithmetic
// across module boundaries; the Mojo caller gets
// a flat NUL-separated buffer + a free()).
//
// `komira_walk_dir_recursive(root, out_buf, out_len)`:
//   Recursively walks `root`, collecting the absolute path of every REGULAR
//   FILE under it (at any depth). Writes a single heap buffer of the paths
//   joined by '\0' (one trailing '\0' per path, including the last) into
//   `*out_buf`, and the total byte length (including all separators) into
//   `*out_len`. Returns 0 on success, -1 on error.
//
//   On success with zero files found, `*out_buf` is a valid 1-byte heap
//   allocation (so the caller can always `free` it) and `*out_len` is 0.
//
//   OWNERSHIP: the caller (Mojo `LocalFs.list`) MUST `free(*out_buf)` via
//   `komira_free` after copying the paths out. The buffer is malloc'd here.
//
// SYMLINK SAFETY (matches DuckDB — do not follow symlinks into cycles):
//   We classify each entry with `lstat(2)` (NOT `stat(2)`), which does NOT
//   dereference symlinks. A symlink is neither a regular file nor a directory
//   under lstat's S_IFMT, so it is SKIPPED entirely — we never emit it as a
//   file and never recurse through it. This makes the walk acyclic by
//   construction (the only way to form a directory cycle on a POSIX fs is via
//   a symlink, and we never traverse one). No visited-inode set is needed.
//
// `d_name` is read as a NUL-terminated C string (robust — no dependence on
// the platform `d_reclen` / `d_namlen` fields or the `d_name` struct offset;
// `readdir` guarantees `d_name` is NUL-terminated on every POSIX platform).
// "." and ".." are skipped.
//
// Pointer discipline: the only pointers crossing the FFI boundary are the
// out-params (`char **out_buf`, `unsigned long *out_len`) the Mojo caller
// owns on its stack frame, plus the malloc'd buffer whose ownership transfers
// to the caller (freed via komira_free). No Mojo origin interaction; the
// recursion + struct parsing is fully TU-internal.
// =============================================================================

#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Grow a heap buffer to hold `needed` more bytes beyond `*used`. Returns 0 on
// success, -1 on allocation failure (leaving the existing buffer intact).
static int _walk_buf_ensure(char **buf, size_t *cap, size_t used,
                            size_t needed) {
    size_t want = used + needed;
    if (want <= *cap) {
        return 0;
    }
    size_t new_cap = (*cap == 0) ? 4096 : *cap;
    while (new_cap < want) {
        new_cap *= 2;
    }
    char *grown = (char *)realloc(*buf, new_cap);
    if (grown == NULL) {
        return -1;
    }
    *buf = grown;
    *cap = new_cap;
    return 0;
}

// Recursive helper. Appends NUL-terminated absolute file paths under `dir`
// into the growable (`*buf`, `*cap`, `*used`). Returns 0 on success, -1 on a
// hard error (allocation failure). A directory that cannot be opened (e.g.
// EACCES) is SKIPPED (best-effort walk), not treated as a hard error.
static int _walk_dir_into(const char *dir, char **buf, size_t *cap,
                          size_t *used) {
    DIR *dp = opendir(dir);
    if (dp == NULL) {
        // Unreadable directory: skip it rather than failing the whole walk.
        return 0;
    }
    size_t dir_len = strlen(dir);
    struct dirent *ent;
    int rc = 0;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        // Skip "." and "..".
        if (name[0] == '.' &&
            (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        // Build the child path: dir + '/' + name (collapse a trailing '/').
        size_t name_len = strlen(name);
        int need_sep = (dir_len > 0 && dir[dir_len - 1] != '/') ? 1 : 0;
        size_t child_len = dir_len + (size_t)need_sep + name_len;
        char *child = (char *)malloc(child_len + 1);
        if (child == NULL) {
            rc = -1;
            break;
        }
        memcpy(child, dir, dir_len);
        size_t off = dir_len;
        if (need_sep) {
            child[off++] = '/';
        }
        memcpy(child + off, name, name_len);
        child[off + name_len] = '\0';

        // Classify WITHOUT following symlinks (lstat). Symlinks fall through
        // both branches -> skipped (cycle-safe).
        struct stat st;
        if (lstat(child, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                rc = _walk_dir_into(child, buf, cap, used);
                if (rc != 0) {
                    free(child);
                    break;
                }
            } else if (S_ISREG(st.st_mode)) {
                if (_walk_buf_ensure(buf, cap, *used, child_len + 1) != 0) {
                    rc = -1;
                    free(child);
                    break;
                }
                memcpy(*buf + *used, child, child_len);
                (*buf)[*used + child_len] = '\0';
                *used += child_len + 1;
            }
            // else: symlink / fifo / socket / device -> skip.
        }
        // lstat failure (race: entry removed mid-walk) -> skip.
        free(child);
    }
    closedir(dp);
    return rc;
}

int komira_walk_dir_recursive(const char *root, char **out_buf,
                               unsigned long *out_len) {
    char *buf = NULL;
    size_t cap = 0;
    size_t used = 0;
    int rc = _walk_dir_into(root, &buf, &cap, &used);
    if (rc != 0) {
        free(buf);
        *out_buf = NULL;
        *out_len = 0;
        return -1;
    }
    // Always hand back a freeable buffer, even for the zero-file case.
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            *out_buf = NULL;
            *out_len = 0;
            return -1;
        }
    }
    *out_buf = buf;
    *out_len = (unsigned long)used;
    return 0;
}

// =============================================================================
// `komira_list_dir_shallow(dir, out_buf, out_len)`:
//   SHALLOW one-level directory listing — the partition-schema probe
//   primitive for lazy Hive discovery. Lists the IMMEDIATE children of
//   `dir` (NOT recursive — this is the whole point: we never enumerate the
//   leaf data files). Each immediate child is emitted as a single
//   NUL-terminated record whose FIRST byte is a TYPE TAG:
//       'D' <name>'\0'   -> the child is a subdirectory
//       'F' <name>'\0'   -> the child is a regular file
//   `<name>` is the bare entry name (NOT the full path — the Mojo caller
//   joins it to `dir`). `*out_len` is the total byte length (tags + names +
//   separators). Returns 0 on success, -1 on error.
//
//   The level-by-level Mojo walk (`LocalFs.list_dir_shallow` ->
//   `_try_build_hive_partitioned_plan`) descends partition_depth levels,
//   reading ONE shallow listing per level to learn the `key=value` partition
//   column name + the distinct values at that level for the type probe, and
//   ONE representative leaf path for the data-schema footer read. The pruned
//   leaf-file enumeration is deferred to the reader that opens the pruned set.
//
//   On success with zero children, `*out_buf` is a valid 1-byte heap
//   allocation and `*out_len` is 0. OWNERSHIP: caller MUST `komira_free`.
//
//   SYMLINK SAFETY: lstat classification (no symlink deref). A symlink is
//   neither 'D' nor 'F' under S_IFMT -> SKIPPED (consistent with the
//   recursive walk's no-follow contract).
// =============================================================================
int komira_list_dir_shallow(const char *dir, char **out_buf,
                             unsigned long *out_len) {
    char *buf = NULL;
    size_t cap = 0;
    size_t used = 0;
    int rc = 0;

    DIR *dp = opendir(dir);
    if (dp != NULL) {
        size_t dir_len = strlen(dir);
        struct dirent *ent;
        while ((ent = readdir(dp)) != NULL) {
            const char *name = ent->d_name;
            // Skip "." and "..".
            if (name[0] == '.' &&
                (name[1] == '\0' ||
                 (name[1] == '.' && name[2] == '\0'))) {
                continue;
            }
            size_t name_len = strlen(name);
            // Build the full child path for the lstat classification.
            int need_sep = (dir_len > 0 && dir[dir_len - 1] != '/') ? 1 : 0;
            size_t child_len = dir_len + (size_t)need_sep + name_len;
            char *child = (char *)malloc(child_len + 1);
            if (child == NULL) {
                rc = -1;
                break;
            }
            memcpy(child, dir, dir_len);
            size_t off = dir_len;
            if (need_sep) {
                child[off++] = '/';
            }
            memcpy(child + off, name, name_len);
            child[off + name_len] = '\0';

            char tag = 0;
            struct stat st;
            if (lstat(child, &st) == 0) {
                if (S_ISDIR(st.st_mode)) {
                    tag = 'D';
                } else if (S_ISREG(st.st_mode)) {
                    tag = 'F';
                }
                // else: symlink / fifo / socket / device -> tag stays 0 (skip).
            }
            free(child);
            if (tag == 0) {
                continue;  // not a dir or regular file -> skip.
            }
            // Emit: <tag> <name> '\0'.
            size_t rec_len = 1 + name_len;
            if (_walk_buf_ensure(&buf, &cap, used, rec_len + 1) != 0) {
                rc = -1;
                break;
            }
            buf[used] = tag;
            memcpy(buf + used + 1, name, name_len);
            buf[used + rec_len] = '\0';
            used += rec_len + 1;
        }
        closedir(dp);
    }
    // (opendir failure -> treated as an empty listing, like the recursive walk.)

    if (rc != 0) {
        free(buf);
        *out_buf = NULL;
        *out_len = 0;
        return -1;
    }
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            *out_buf = NULL;
            *out_len = 0;
            return -1;
        }
    }
    *out_buf = buf;
    *out_len = (unsigned long)used;
    return 0;
}

// Free a buffer returned by komira_walk_dir_recursive. Renamed (not bare
// `free`) to sidestep any stdlib FFI name reservation, matching the
// the other renamed wrappers in this file. Returns 0
// (an `int` return keeps the Mojo external_call site uniform with the other
// shims; the value is ignored by the caller).
int komira_free(void *p) {
    free(p);
    return 0;
}
