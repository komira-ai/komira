// Non-variadic C wrappers over the POSIX calls komira_core makes, plus the
// process-global counters its Mojo code shares across threads.
//
// Why wrappers: `open`, `openat` and `fcntl` are variadic in C, and a Mojo
// `external_call` cannot pass arguments through a C variadic ABI safely; each
// wrapper here has a fixed arity. The remaining wrappers fix the integer
// widths at the boundary (`off_t`, `size_t`, `mode_t` differ by platform) so
// the Mojo side always passes `Int64`/`UInt64`/`Int32`.
//
// Every function takes and returns plain integers or a caller-owned buffer;
// no pointer is retained past the call. The counters are process-resident
// statics updated with relaxed atomics: they carry no happens-before
// guarantee and are only read as totals.
//
// This file is the only definition of these symbols. A package that needs one
// of them depends on komira_core rather than defining its own copy.

#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Process-global counters.
// ---------------------------------------------------------------------------

static uint64_t _inmem_source_counter = 0;

// A process-unique, never-zero id for each in-memory source.
uint64_t komira_next_inmem_source_id(void) {
    return __atomic_fetch_add(&_inmem_source_counter, 1, __ATOMIC_RELAXED) + 1;
}

static int64_t _on_pool_depth = 0;

// Depth of executor-pool dispatches in flight. A dispatch site brackets its
// fan-out with enter/exit; code that would start a nested parallel loop reads
// the depth and stays serial while it is above zero, so a pool worker never
// oversubscribes the cores the pool already holds.
int64_t komira_on_pool_enter(void) {
    return __atomic_add_fetch(&_on_pool_depth, 1, __ATOMIC_RELAXED);
}

int64_t komira_on_pool_exit(void) {
    return __atomic_sub_fetch(&_on_pool_depth, 1, __ATOMIC_RELAXED);
}

int64_t komira_on_pool_depth(void) {
    return __atomic_load_n(&_on_pool_depth, __ATOMIC_RELAXED);
}

// ---------------------------------------------------------------------------
// File descriptors.
// ---------------------------------------------------------------------------

// Set O_NONBLOCK; -1 if the current flags cannot be read.
int komira_fcntl_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int komira_openat_creat(int dirfd, const char *path, int oflag, int mode) {
    return openat(dirfd, path, oflag, (mode_t)mode);
}

int komira_open_ro(const char *path) {
    return openat(AT_FDCWD, path, O_RDONLY);
}

long long komira_write_bytes(int fd, const void *buf, unsigned long count) {
    return (long long)write(fd, buf, (size_t)count);
}

long long komira_writev_iov(int fd, const struct iovec *iov, int iovcnt) {
    return (long long)writev(fd, iov, iovcnt);
}

long long komira_pwrite(int fd, const void *buf, unsigned long count,
                        long long offset) {
    return (long long)pwrite(fd, buf, (size_t)count, (off_t)offset);
}

int komira_ftruncate(int fd, long long length) {
    return ftruncate(fd, (off_t)length);
}

int komira_fsync(int fd) {
    return fsync(fd);
}

long long komira_lseek_end(int fd) {
    return (long long)lseek(fd, (off_t)0, SEEK_END);
}

// File size in bytes, or -1 if fstat fails.
long long komira_fstat_size(int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) {
        return -1;
    }
    return (long long)st.st_size;
}

// ---------------------------------------------------------------------------
// Memory maps.
// ---------------------------------------------------------------------------

static _Atomic long long _mmap_ro_calls = 0;

// Map the first `length` bytes of `fd` read-only and private; NULL on failure.
void *komira_mmap_ro(int fd, long long length) {
    void *p = mmap(NULL, (size_t)length, PROT_READ, MAP_PRIVATE, fd, (off_t)0);
    if (p == MAP_FAILED) {
        return NULL;
    }
    atomic_fetch_add_explicit(&_mmap_ro_calls, 1, memory_order_relaxed);
    return p;
}

// Number of successful komira_mmap_ro calls in this process.
long long komira_mmap_ro_count(void) {
    return atomic_load_explicit(&_mmap_ro_calls, memory_order_relaxed);
}

int komira_munmap(void *addr, unsigned long length) {
    return munmap(addr, (size_t)length);
}

static _Atomic long long _madvise_willneed_bytes_total = 0;

// Total bytes passed to MADV_WILLNEED by the two calls below.
long long komira_madvise_willneed_bytes(void) {
    return atomic_load_explicit(&_madvise_willneed_bytes_total,
                                memory_order_relaxed);
}

int komira_madvise_willneed(void *addr, unsigned long length) {
    atomic_fetch_add_explicit(&_madvise_willneed_bytes_total,
                              (long long)length, memory_order_relaxed);
    return madvise(addr, (size_t)length, MADV_WILLNEED);
}

// MADV_WILLNEED over [offset, offset + length) of a mapping of `region_len`
// bytes at `base`. The start is rounded down to a page boundary and the span
// rounded up to whole pages, but never past the end of the mapping (advising
// an address range outside the mapping fails with ENOMEM). Returns -1 for an
// empty or out-of-range request.
int komira_madvise_willneed_range(void *base,
                                  unsigned long long region_len,
                                  unsigned long long offset,
                                  unsigned long long length) {
    if (base == NULL || region_len == 0 || length == 0) {
        return -1;
    }
    if (offset >= region_len) {
        return -1;
    }
    unsigned long long end = offset + length;
    if (end < offset) {  // overflow
        return -1;
    }
    if (end > region_len) {
        end = region_len;
    }
    long ps_signed = sysconf(_SC_PAGESIZE);
    unsigned long long ps =
        (ps_signed > 0) ? (unsigned long long)ps_signed : 4096ULL;
    unsigned long long start = offset - (offset % ps);
    unsigned long long span = end - start;
    unsigned long long rem = span % ps;
    if (rem != 0) {
        unsigned long long pad = ps - rem;
        if (start + span + pad <= region_len) {
            span += pad;
        } else {
            span = region_len - start;
        }
    }
    atomic_fetch_add_explicit(&_madvise_willneed_bytes_total,
                              (long long)span, memory_order_relaxed);
    return madvise((char *)base + start, (size_t)span, MADV_WILLNEED);
}

// ---------------------------------------------------------------------------
// Paths.
// ---------------------------------------------------------------------------

// Fill out5 with {size, mtime_ns, inode, device, age_ns} for `path`, where
// age_ns is the wall-clock time since the last modification. -1 if stat fails.
int komira_stat_identity(const char *path, long long *out5) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return -1;
    }
    long long mtime_ns;
#if defined(__APPLE__)
    mtime_ns = (long long)st.st_mtimespec.tv_sec * 1000000000LL +
               (long long)st.st_mtimespec.tv_nsec;
#else
    mtime_ns = (long long)st.st_mtim.tv_sec * 1000000000LL +
               (long long)st.st_mtim.tv_nsec;
#endif
    struct timespec now;
    long long now_ns;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
        now_ns = mtime_ns;
    } else {
        now_ns = (long long)now.tv_sec * 1000000000LL + (long long)now.tv_nsec;
    }
    out5[0] = (long long)st.st_size;
    out5[1] = mtime_ns;
    out5[2] = (long long)st.st_ino;
    out5[3] = (long long)st.st_dev;
    out5[4] = now_ns - mtime_ns;
    return 0;
}

// Set both the access and modification time of `path` to `mtime_ns`.
int komira_set_mtime_ns(const char *path, long long mtime_ns) {
    struct timespec times[2];
    times[0].tv_sec = (time_t)(mtime_ns / 1000000000LL);
    times[0].tv_nsec = (long)(mtime_ns % 1000000000LL);
    times[1] = times[0];
    return utimensat(AT_FDCWD, path, times, 0);
}

// Read up to `max_bytes` of `path` (the whole file when max_bytes <= 0) and
// discard it, so a later read of the same range is served from the page
// cache. Returns -1 if the file cannot be opened; a short read is not an
// error, because the caller's own read is what guarantees correctness.
int komira_prefetch_file(const char *path, long long max_bytes) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
#if defined(__linux__) && defined(POSIX_FADV_WILLNEED)
    (void)posix_fadvise(fd, (off_t)0,
                        (max_bytes > 0 ? (off_t)max_bytes : (off_t)0),
                        POSIX_FADV_WILLNEED);
#endif
    char buf[65536];
    long long remaining = max_bytes;
    int bounded = (max_bytes > 0);
    while (1) {
        size_t want = sizeof(buf);
        if (bounded) {
            if (remaining <= 0) break;
            if ((long long)want > remaining) want = (size_t)remaining;
        }
        ssize_t n = read(fd, buf, want);
        if (n <= 0) break;
        if (bounded) remaining -= (long long)n;
    }
    close(fd);
    return 0;
}
