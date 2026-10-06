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
//   `*out_len`. Returns 0 on success, or the POSITIVE errno of the failing
//   call (ENOMEM for an allocation failure). On failure the path whose
//   opendir / readdir / lstat failed is written NUL-terminated (truncated to
//   fit) into the caller's `err_path` buffer of `err_cap` bytes.
//
//   ONLY ENOENT MEANS "NOT THERE". An opendir of the ROOT that fails returns
//   its errno, ENOENT included (the Mojo caller decides that a missing root
//   lists empty). Below the root, an entry or directory that vanished between
//   readdir and lstat/opendir (ENOENT) is skipped: it is genuinely gone. Every
//   OTHER failure (EACCES, EMFILE, ELOOP, EIO, a readdir error, ...) fails the
//   whole walk: silently skipping an unreadable directory drops its files from
//   the listing with no error.
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
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
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

// Copy `path` (NUL-terminated, truncated to fit) into the caller's error
// buffer. A NULL buffer or zero capacity writes nothing.
static void _set_err_path(char *err_path, unsigned long err_cap,
                          const char *path) {
    if (err_path == NULL || err_cap == 0) {
        return;
    }
    size_t len = strlen(path);
    if (len > err_cap - 1) {
        len = err_cap - 1;
    }
    memcpy(err_path, path, len);
    err_path[len] = '\0';
}

// Recursive helper. Appends NUL-terminated absolute file paths under `dir`
// into the growable (`*buf`, `*cap`, `*used`). Returns 0 on success or the
// positive errno of the failing call (see the contract above); `is_root`
// says whether an ENOENT from opendir(dir) is reported (root) or skipped (a
// subdirectory removed mid-walk).
static int _walk_dir_into(const char *dir, int is_root, char **buf,
                          size_t *cap, size_t *used, char *err_path,
                          unsigned long err_cap) {
    DIR *dp = opendir(dir);
    if (dp == NULL) {
        int e = errno;
        if (!is_root && e == ENOENT) {
            return 0;  // removed between readdir and opendir: gone.
        }
        _set_err_path(err_path, err_cap, dir);
        return e;
    }
    size_t dir_len = strlen(dir);
    struct dirent *ent;
    int rc = 0;
    for (;;) {
        errno = 0;
        ent = readdir(dp);
        if (ent == NULL) {
            if (errno != 0) {
                rc = errno;
                _set_err_path(err_path, err_cap, dir);
            }
            break;
        }
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
            rc = ENOMEM;
            _set_err_path(err_path, err_cap, dir);
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
                rc = _walk_dir_into(child, 0, buf, cap, used, err_path,
                                    err_cap);
                if (rc != 0) {
                    free(child);
                    break;
                }
            } else if (S_ISREG(st.st_mode)) {
                if (_walk_buf_ensure(buf, cap, *used, child_len + 1) != 0) {
                    rc = ENOMEM;
                    _set_err_path(err_path, err_cap, child);
                    free(child);
                    break;
                }
                memcpy(*buf + *used, child, child_len);
                (*buf)[*used + child_len] = '\0';
                *used += child_len + 1;
            }
            // else: symlink / fifo / socket / device -> skip.
        } else if (errno != ENOENT) {
            // A real lstat failure: the entry exists but cannot be classified.
            rc = errno;
            _set_err_path(err_path, err_cap, child);
            free(child);
            break;
        }
        // lstat ENOENT (entry removed mid-walk) -> skip: it is gone.
        free(child);
    }
    closedir(dp);
    return rc;
}

int komira_walk_dir_recursive(const char *root, char **out_buf,
                               unsigned long *out_len, char *err_path,
                               unsigned long err_cap) {
    char *buf = NULL;
    size_t cap = 0;
    size_t used = 0;
    *out_buf = NULL;
    *out_len = 0;
    _set_err_path(err_path, err_cap, "");
    int rc = _walk_dir_into(root, 1, &buf, &cap, &used, err_path, err_cap);
    if (rc != 0) {
        free(buf);
        return rc;
    }
    // Always hand back a freeable buffer, even for the zero-file case.
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            _set_err_path(err_path, err_cap, root);
            return ENOMEM;
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
//   separators). Returns 0 on success, or the POSITIVE errno of the failing
//   call (ENOMEM for an allocation failure).
//
//   ONLY ENOENT MEANS "NOT THERE". An opendir failure returns its errno,
//   ENOENT included (the Mojo caller maps a missing `dir` to an empty
//   listing); it is NOT an empty listing here, because a directory that
//   exists but cannot be opened (EACCES, EMFILE, ...) would otherwise read as
//   empty. A readdir error fails the listing; an lstat ENOENT (child removed
//   mid-listing) skips the child; any other lstat failure fails the listing.
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

    *out_buf = NULL;
    *out_len = 0;
    DIR *dp = opendir(dir);
    if (dp == NULL) {
        return errno;
    }
    {
        size_t dir_len = strlen(dir);
        struct dirent *ent;
        for (;;) {
            errno = 0;
            ent = readdir(dp);
            if (ent == NULL) {
                if (errno != 0) {
                    rc = errno;
                }
                break;
            }
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
                rc = ENOMEM;
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
            } else if (errno != ENOENT) {
                rc = errno;  // exists but cannot be classified: fail.
                free(child);
                break;
            }
            // lstat ENOENT (child removed mid-listing) -> skip: it is gone.
            free(child);
            if (tag == 0) {
                continue;  // not a dir or regular file -> skip.
            }
            // Emit: <tag> <name> '\0'.
            size_t rec_len = 1 + name_len;
            if (_walk_buf_ensure(&buf, &cap, used, rec_len + 1) != 0) {
                rc = ENOMEM;
                break;
            }
            buf[used] = tag;
            memcpy(buf + used + 1, name, name_len);
            buf[used + rec_len] = '\0';
            used += rec_len + 1;
        }
        closedir(dp);
    }

    if (rc != 0) {
        free(buf);
        return rc;
    }
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            return ENOMEM;
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

// =============================================================================
// errno surface for the Mojo side (local_fs_probe.mojo). Mojo never spells an
// errno number: it compares against `komira_fs_enoent()` and renders a name
// with `komira_fs_errno_name`.
// =============================================================================

// The platform's ENOENT, the one errno that means "no such path".
int32_t komira_fs_enoent(void) { return (int32_t)ENOENT; }

#define KOMIRA_FS_KIND_REGULAR 1
#define KOMIRA_FS_KIND_DIRECTORY 2
#define KOMIRA_FS_KIND_OTHER 3

// Classify `path`: stat(2) when `follow` is non-zero, lstat(2) otherwise.
// Returns 0 and writes a KOMIRA_FS_KIND_* value, or returns the errno (read
// immediately after the failing call). `*out_kind` is 0 on failure.
int32_t komira_fs_path_kind(const char *path, int32_t follow,
                            int32_t *out_kind) {
    struct stat st;
    *out_kind = 0;
    int rc = follow ? stat(path, &st) : lstat(path, &st);
    if (rc != 0) {
        return (int32_t)errno;
    }
    if (S_ISREG(st.st_mode)) {
        *out_kind = KOMIRA_FS_KIND_REGULAR;
    } else if (S_ISDIR(st.st_mode)) {
        *out_kind = KOMIRA_FS_KIND_DIRECTORY;
    } else {
        *out_kind = KOMIRA_FS_KIND_OTHER;
    }
    return 0;
}

// Write the symbolic name of errno `e` ("ENOENT", "EACCES", ...) into `buf`
// (capacity `cap`, NUL-terminated, truncated to fit) and return its length.
// An errno this table does not name is written as "E?".
int64_t komira_fs_errno_name(int32_t e, uint8_t *buf, int64_t cap) {
    const char *name = "E?";
    switch (e) {
#define KOMIRA_FS_NAME(x) \
    case x:               \
        name = #x;        \
        break;
        KOMIRA_FS_NAME(EPERM)
        KOMIRA_FS_NAME(ENOENT)
        KOMIRA_FS_NAME(EINTR)
        KOMIRA_FS_NAME(EIO)
        KOMIRA_FS_NAME(ENXIO)
        KOMIRA_FS_NAME(EBADF)
        KOMIRA_FS_NAME(EAGAIN)
        KOMIRA_FS_NAME(ENOMEM)
        KOMIRA_FS_NAME(EACCES)
        KOMIRA_FS_NAME(EFAULT)
        KOMIRA_FS_NAME(EBUSY)
        KOMIRA_FS_NAME(EEXIST)
        KOMIRA_FS_NAME(ENODEV)
        KOMIRA_FS_NAME(ENOTDIR)
        KOMIRA_FS_NAME(EISDIR)
        KOMIRA_FS_NAME(EINVAL)
        KOMIRA_FS_NAME(ENFILE)
        KOMIRA_FS_NAME(EMFILE)
        KOMIRA_FS_NAME(ETXTBSY)
        KOMIRA_FS_NAME(EFBIG)
        KOMIRA_FS_NAME(ENOSPC)
        KOMIRA_FS_NAME(EROFS)
        KOMIRA_FS_NAME(ENAMETOOLONG)
        KOMIRA_FS_NAME(ELOOP)
        KOMIRA_FS_NAME(EOVERFLOW)
        KOMIRA_FS_NAME(ENOTEMPTY)
#ifdef ESTALE
        KOMIRA_FS_NAME(ESTALE)
#endif
#ifdef EDQUOT
        KOMIRA_FS_NAME(EDQUOT)
#endif
#undef KOMIRA_FS_NAME
        default:
            break;
    }
    if (cap <= 0) {
        return 0;
    }
    size_t len = strlen(name);
    if ((int64_t)len > cap - 1) {
        len = (size_t)(cap - 1);
    }
    memcpy(buf, name, len);
    buf[len] = 0;
    return (int64_t)len;
}

// =============================================================================
// TEST SEAM (tests/test_local_fs_errno_not_absent.mojo only). Forces EMFILE on
// the SECOND descriptor a caller opens, which lets a test reach the walk's
// below-root opendir failure even when it runs privileged (root bypasses
// file modes, so EACCES cannot be forced; RLIMIT_NOFILE binds root too).
// RLIMIT_NOFILE and `struct rlimit` are platform definitions, so they stay in
// C. Not called by any library code.
// =============================================================================

// Lower the soft RLIMIT_NOFILE so exactly ONE more descriptor can be opened:
// the lowest free fd L is found by opening /dev/null (then closed), and the
// soft limit becomes L + 1, so the next open gets L and the one after fails
// with EMFILE. Writes the previous soft limit for `komira_fs_test_set_nofile_soft`.
// Returns 0 or the errno.
int32_t komira_fs_test_allow_one_more_fd(int64_t *old_soft) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return (int32_t)errno;
    }
    *old_soft = (int64_t)rl.rlim_cur;
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return (int32_t)errno;
    }
    close(fd);
    rl.rlim_cur = (rlim_t)fd + 1;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return (int32_t)errno;
    }
    return 0;
}

// Restore the soft RLIMIT_NOFILE to `soft` (a value the caller read before).
// Returns 0 or the errno.
int32_t komira_fs_test_set_nofile_soft(int64_t soft) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return (int32_t)errno;
    }
    rl.rlim_cur = (rlim_t)soft;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return (int32_t)errno;
    }
    return 0;
}
