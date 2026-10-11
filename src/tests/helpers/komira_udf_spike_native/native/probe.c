/*
 * What the native runtime's tests read about the process:
 *   - the number of objects the dynamic loader has mapped (dl_iterate_phdr
 *     counts the program, every shared library and the vDSO). A library the
 *     native runtime dlopens adds one; a library it refuses before dlopen
 *     adds none.
 *   - the bytes of the C heap in use (glibc's mallinfo2: the main arena's
 *     allocated chunks plus the blocks it mapped), for test_leaks.
 *   - the number of open file descriptors (/proc/self/fd).
 *   - descriptor 0: closing it, whether it is open, and whether it names the
 *     native runtime's library memory file (test_stdin_closed).
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <link.h>
#include <malloc.h>
#include <stddef.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

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

/* The descriptors open in this process; the directory's own descriptor is
 * in the count, the same one in every count. -1 if /proc is not readable. */
int64_t komira_udf_spike_open_fds(void) {
  DIR* d = opendir("/proc/self/fd");
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

/* 1 when descriptor 0 names the native runtime's library memory file. */
int64_t komira_udf_spike_stdin_is_library_memfd(void) {
  char buf[256];
  ssize_t n = readlink("/proc/self/fd/0", buf, sizeof(buf) - 1);
  if (n < 0) return 0;
  buf[n] = 0;
  return strstr(buf, "memfd:komira-udf-native-library") != NULL ? 1 : 0;
}
