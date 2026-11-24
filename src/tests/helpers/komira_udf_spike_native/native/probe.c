/*
 * What the native runtime's tests read about the process:
 *   - the number of objects the dynamic loader has mapped (Linux:
 *     dl_iterate_phdr counts the program, every shared library and the
 *     vDSO; macOS: dyld's image count, the program and every library). A
 *     library the native runtime dlopens adds one; a library it refuses
 *     before dlopen adds none.
 *   - the bytes of the C heap in use (Linux: glibc's mallinfo2, the main
 *     arena's allocated chunks plus the blocks it mapped; macOS: the bytes in
 *     use in every malloc zone), for test_leaks.
 *   - the number of open file descriptors (Linux: /proc/self/fd; macOS:
 *     /dev/fd, which lists this process's descriptors).
 *   - descriptor 0: closing it, whether it is open, and whether it names the
 *     native runtime's library memory file (test_stdin_closed).
 * test_probe holds each of these to what it should count, on the system it
 * runs on.
 */
#define _GNU_SOURCE
#include <dirent.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <malloc/malloc.h>
#else
#include <link.h>
#include <malloc.h>
#endif
#include <stddef.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __APPLE__
int64_t komira_udf_spike_loaded_objects(void) { return (int64_t)_dyld_image_count(); }

int64_t komira_udf_spike_heap_in_use(void) {
  malloc_statistics_t s;
  memset(&s, 0, sizeof(s));
  malloc_zone_statistics(NULL, &s);
  return (int64_t)s.size_in_use;
}

#define FD_DIR "/dev/fd"
#else
static int count(struct dl_phdr_info* info, size_t size, void* data) {
  (void)info;
  (void)size;
  (*(int64_t*)data)++;
  return 0;
}

int64_t komira_udf_spike_loaded_objects(void) {
  int64_t n = 0;
  dl_iterate_phdr(count, &n);
  return n;
}

int64_t komira_udf_spike_heap_in_use(void) {
  struct mallinfo2 m = mallinfo2();
  return (int64_t)m.uordblks + (int64_t)m.hblkhd;
}

#define FD_DIR "/proc/self/fd"
#endif

/* For the probe's own test: hold `bytes` of the C heap (malloc'd and
 * written) until komira_udf_spike_heap_drop. 1, or 0 when a block is already
 * held, `bytes` is not positive or malloc failed. */
static void* held;

int64_t komira_udf_spike_heap_hold(int64_t bytes) {
  if (held != NULL || bytes <= 0) return 0;
  held = malloc((size_t)bytes);
  if (held == NULL) return 0;
  memset(held, 1, (size_t)bytes);
  return 1;
}

void komira_udf_spike_heap_drop(void) {
  free(held);
  held = NULL;
}

/* The descriptors open in this process; the directory's own descriptor is
 * in the count, the same one in every count. -1 if the directory is not
 * readable. */
int64_t komira_udf_spike_open_fds(void) {
  DIR* d = opendir(FD_DIR);
  if (d == NULL) return -1;
  int64_t n = 0;
  for (struct dirent* e = readdir(d); e != NULL; e = readdir(d))
    if (e->d_name[0] != '.') n++;
  closedir(d);
  return n;
}

/* Close standard input, so the next descriptor this process opens is 0. */
int64_t komira_udf_spike_close_stdin(void) { return close(0) == 0 ? 1 : 0; }

/* 1 when descriptor 0 is open. */
int64_t komira_udf_spike_stdin_open(void) { return fcntl(0, F_GETFD) != -1 ? 1 : 0; }

/* 1 when descriptor 0 names the native runtime's library memory file. The
 * runtime makes that file on Linux only (native_runtime.c, open_bytes), so
 * on macOS descriptor 0 never names it. */
int64_t komira_udf_spike_stdin_is_library_memfd(void) {
#ifdef __APPLE__
  return 0;
#else
  char buf[256];
  ssize_t n = readlink("/proc/self/fd/0", buf, sizeof(buf) - 1);
  if (n < 0) return 0;
  buf[n] = 0;
  return strstr(buf, "memfd:komira-udf-native-library") != NULL ? 1 : 0;
#endif
}
