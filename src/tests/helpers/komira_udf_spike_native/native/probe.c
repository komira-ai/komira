/*
 * What the native runtime's tests read about the process:
 *   - the number of objects the dynamic loader has mapped (dl_iterate_phdr
 *     counts the program, every shared library and the vDSO). A library the
 *     native runtime dlopens adds one; a library it refuses before dlopen
 *     adds none.
 *   - the bytes of the C heap in use (glibc's mallinfo2: the main arena's
 *     allocated chunks plus the blocks it mapped), for test_leaks.
 *   - the number of open file descriptors (/proc/self/fd).
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <link.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>

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
