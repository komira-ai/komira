// =============================================================================
// komira_objectstore/_objectstore_shim.c
//   The errno-surfacing file primitives behind LocalFsConditionalStore.
// =============================================================================
//
// WHY C. The local-filesystem store must tell "the object file does not exist"
// (ENOENT, the only answer that may become a 404) from every other failure
// (EACCES, EMFILE, ENOTDIR, EIO, EISDIR, ...), which must raise. That needs
// errno, read IMMEDIATELY after the failing call on the same thread, and the
// errno CONSTANTS, whose values differ between platforms. Both live here so no
// errno number is spelled in Mojo and no errno read can be separated from its
// call by another libc call.
//
// CONTRACT. Every function returns 0 on success or the POSITIVE errno of the
// failing call. Nothing is allocated; every pointer argument is a caller-owned
// buffer or out-param that must stay valid for the duration of the call only.
// The fd returned by `komira_objstore_open_for_read` is owned by the caller
// until it is passed to `komira_objstore_read_exact_close`, which closes it on
// every path.
// =============================================================================

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Which call failed (reported in the Mojo error message). Mirrored by the
// `_STAGE_*` comptime values in local_fs_file_read.mojo.
#define KOMIRA_OBJSTORE_STAGE_OPEN 1
#define KOMIRA_OBJSTORE_STAGE_FSTAT 2
#define KOMIRA_OBJSTORE_STAGE_READ 3
#define KOMIRA_OBJSTORE_STAGE_STAT 4

// Path kinds for `komira_objstore_path_kind`.
#define KOMIRA_OBJSTORE_KIND_REGULAR 1
#define KOMIRA_OBJSTORE_KIND_DIRECTORY 2
#define KOMIRA_OBJSTORE_KIND_OTHER 3

// The platform's ENOENT, the one errno that means "no such object".
int32_t komira_objstore_enoent(void) { return (int32_t)ENOENT; }

// Open `path` read-only and report its size. On success writes the fd and the
// size and returns 0. On failure returns the errno and writes the stage that
// failed; no fd is left open. A directory is refused with EISDIR (reading one
// is never an object read, and its size is meaningless).
int32_t komira_objstore_open_for_read(const char *path, int32_t *out_fd,
                                      int64_t *out_size, int32_t *out_stage) {
    *out_fd = -1;
    *out_size = 0;
    *out_stage = KOMIRA_OBJSTORE_STAGE_OPEN;
    int fd;
    do {
        fd = open(path, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        return (int32_t)errno;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        *out_stage = KOMIRA_OBJSTORE_STAGE_FSTAT;
        return (int32_t)e;
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        *out_stage = KOMIRA_OBJSTORE_STAGE_FSTAT;
        return (int32_t)EISDIR;
    }
    *out_fd = (int32_t)fd;
    *out_size = (int64_t)st.st_size;
    return 0;
}

// Read up to `n` bytes from `fd` into `buf` (retrying EINTR and partial
// reads), then close `fd` on every path. Writes the byte count read; a count
// below `n` with a 0 return means end of file came first (the caller decides).
int32_t komira_objstore_read_exact_close(int32_t fd, uint8_t *buf, int64_t n,
                                         int64_t *out_got) {
    int64_t got = 0;
    int32_t rc = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, (size_t)(n - got));
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            rc = (int32_t)errno;
            break;
        }
        if (r == 0) {
            break;
        }
        got += (int64_t)r;
    }
    *out_got = got;
    close(fd);
    return rc;
}

// Classify `path` with stat(2) (symlinks followed, as open(2) follows them).
// Returns 0 and writes a KIND_* value, or returns the errno.
int32_t komira_objstore_path_kind(const char *path, int32_t *out_kind) {
    struct stat st;
    *out_kind = 0;
    if (stat(path, &st) != 0) {
        return (int32_t)errno;
    }
    if (S_ISREG(st.st_mode)) {
        *out_kind = KOMIRA_OBJSTORE_KIND_REGULAR;
    } else if (S_ISDIR(st.st_mode)) {
        *out_kind = KOMIRA_OBJSTORE_KIND_DIRECTORY;
    } else {
        *out_kind = KOMIRA_OBJSTORE_KIND_OTHER;
    }
    return 0;
}

// remove(3) `path`. Returns 0, or the errno read immediately after the
// failing call.
int32_t komira_objstore_remove(const char *path) {
    if (remove(path) == 0) {
        return 0;
    }
    return (int32_t)errno;
}

// Write the symbolic name of errno `e` ("ENOENT", "EACCES", ...) into `buf`
// (capacity `cap`, NUL-terminated, truncated to fit) and return its length.
// An errno this table does not name is written as "E?".
int64_t komira_objstore_errno_name(int32_t e, uint8_t *buf, int64_t cap) {
    const char *name = "E?";
    switch (e) {
#define KOMIRA_OBJSTORE_NAME(x) \
    case x:                     \
        name = #x;              \
        break;
        KOMIRA_OBJSTORE_NAME(EPERM)
        KOMIRA_OBJSTORE_NAME(ENOENT)
        KOMIRA_OBJSTORE_NAME(EINTR)
        KOMIRA_OBJSTORE_NAME(EIO)
        KOMIRA_OBJSTORE_NAME(ENXIO)
        KOMIRA_OBJSTORE_NAME(EBADF)
        KOMIRA_OBJSTORE_NAME(EAGAIN)
        KOMIRA_OBJSTORE_NAME(ENOMEM)
        KOMIRA_OBJSTORE_NAME(EACCES)
        KOMIRA_OBJSTORE_NAME(EFAULT)
        KOMIRA_OBJSTORE_NAME(EBUSY)
        KOMIRA_OBJSTORE_NAME(EEXIST)
        KOMIRA_OBJSTORE_NAME(ENODEV)
        KOMIRA_OBJSTORE_NAME(ENOTDIR)
        KOMIRA_OBJSTORE_NAME(EISDIR)
        KOMIRA_OBJSTORE_NAME(EINVAL)
        KOMIRA_OBJSTORE_NAME(ENFILE)
        KOMIRA_OBJSTORE_NAME(EMFILE)
        KOMIRA_OBJSTORE_NAME(ETXTBSY)
        KOMIRA_OBJSTORE_NAME(EFBIG)
        KOMIRA_OBJSTORE_NAME(ENOSPC)
        KOMIRA_OBJSTORE_NAME(EROFS)
        KOMIRA_OBJSTORE_NAME(ENAMETOOLONG)
        KOMIRA_OBJSTORE_NAME(ELOOP)
        KOMIRA_OBJSTORE_NAME(EOVERFLOW)
        KOMIRA_OBJSTORE_NAME(ENOTEMPTY)
#ifdef ESTALE
        KOMIRA_OBJSTORE_NAME(ESTALE)
#endif
#ifdef EDQUOT
        KOMIRA_OBJSTORE_NAME(EDQUOT)
#endif
#undef KOMIRA_OBJSTORE_NAME
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
