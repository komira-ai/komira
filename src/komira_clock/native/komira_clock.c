/*
 * komira_clock.c -- the process clocks, with the platform's clock ids and the
 * `struct timespec` read kept in C.
 *
 * Mojo cannot see <time.h>, so it cannot know the clock ids (CLOCK_MONOTONIC
 * is 1 on Linux; CLOCK_THREAD_CPUTIME_ID is 3 on Linux and 16 on macOS;
 * CLOCK_UPTIME_RAW exists only on macOS) or the layout of `struct timespec`.
 * This file owns all of that and hands Mojo plain integers: three functions
 * of no arguments, each returning nanoseconds as an unsigned 64-bit integer,
 * or 0 when the platform refuses the read. Nothing here takes or returns a
 * pointer, so the Mojo side has no pointer to get wrong.
 *
 *   komira_clock_monotonic_ns()    monotonic nanoseconds, for intervals.
 *   komira_clock_realtime_ns()     nanoseconds since the Unix epoch.
 *   komira_clock_thread_cpu_ns()   CPU nanoseconds of the calling thread.
 *
 * The preprocessor picks the clock per platform:
 *
 *   * macOS: the monotonic clock is clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
 *     which returns the integer directly (no timespec) and is monotonic since
 *     boot with no leap-second smoothing.
 *   * Linux (and any other POSIX system): CLOCK_MONOTONIC, a vDSO call on
 *     x86_64 and aarch64 (no system call).
 */

#if !defined(__APPLE__)
/* clock_gettime and the CLOCK_* ids are POSIX.1b; ask for them explicitly so
 * a strict -std flag does not hide them. macOS exposes them by default and
 * hides some behind a feature macro, so the macro is not set there. */
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdint.h>
#include <time.h>

#define KOMIRA_CLOCK_NS_PER_SEC UINT64_C(1000000000)

/* Nanoseconds on `clock_id`, or 0 if clock_gettime fails. */
static uint64_t komira_clock_read(clockid_t clock_id) {
    struct timespec ts;
    if (clock_gettime(clock_id, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * KOMIRA_CLOCK_NS_PER_SEC + (uint64_t)ts.tv_nsec;
}

uint64_t komira_clock_monotonic_ns(void) {
#if defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return komira_clock_read(CLOCK_MONOTONIC);
#endif
}

uint64_t komira_clock_realtime_ns(void) {
    return komira_clock_read(CLOCK_REALTIME);
}

uint64_t komira_clock_thread_cpu_ns(void) {
    return komira_clock_read(CLOCK_THREAD_CPUTIME_ID);
}
