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
 *   - descriptor 0: closing it, whether it is open, and whether it is the
 *     native runtime's private copy of a verified library (Linux: the memory
 *     file; macOS: a file in the runtime's private directory), for
 *     test_stdin_closed.
 *   - the files the runtime holds as private copies on macOS (none on
 *     Linux, where the copy is a memory file and a descriptor): after a
 *     refused load none is left.
 *   - the longest path the system accepts (PATH_MAX), which the runtime's
 *     path buffer has as well.
 * test_probe holds each of these to what it should count, on the system it
 * runs on.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <limits.h>
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* macOS: the runtime names its private directory this prefix and six random
 * characters, and a copy by the 64 hex digits of its sha256
 * (native_runtime.c, PRIVATE_DIR_PREFIX and open_bytes). */
#define PRIVATE_DIR_PREFIX "komira-udf-"
#define PRIVATE_DIR_RANDOM 6
#define COPY_NAME_LEN 64

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

/* 1 when descriptor 0 is the native runtime's private copy of a verified
 * library. Linux: the memory file the runtime makes (named
 * "memfd:komira-udf-native-library"). macOS: a file whose name is 64 hex
 * digits in a directory named PRIVATE_DIR_PREFIX and six characters. */
int64_t komira_udf_spike_stdin_is_library_copy(void) {
#ifdef __APPLE__
  char path[PATH_MAX];
  if (fcntl(0, F_GETPATH, path) == -1) return 0;
  const char* name = strrchr(path, '/');
  if (name == NULL || strlen(name + 1) != COPY_NAME_LEN) return 0;
  for (const char* c = name + 1; *c != 0; c++)
    if (!((*c >= '0' && *c <= '9') || (*c >= 'a' && *c <= 'f'))) return 0;
  size_t dir_len = strlen(PRIVATE_DIR_PREFIX) + PRIVATE_DIR_RANDOM;
  if ((size_t)(name - path) < dir_len + 1) return 0;
  const char* dir = name - dir_len;
  return dir[-1] == '/' && strncmp(dir, PRIVATE_DIR_PREFIX, strlen(PRIVATE_DIR_PREFIX)) == 0 ? 1 : 0;
#else
  char buf[256];
  ssize_t n = readlink("/proc/self/fd/0", buf, sizeof(buf) - 1);
  if (n < 0) return 0;
  buf[n] = 0;
  return strstr(buf, "memfd:komira-udf-native-library") != NULL ? 1 : 0;
#endif
}

/* The files held as private copies by the runtimes of this process: on
 * macOS, the entries of every directory under the scratch directory (TMPDIR
 * when set and not empty, else the user's temporary directory, as the
 * runtime reads it) named PRIVATE_DIR_PREFIX and six characters; on Linux 0,
 * the copy being a memory file counted among the descriptors. -1 when the
 * scratch directory is not readable. */
int64_t komira_udf_spike_private_copies(void) {
#ifdef __APPLE__
  char base[PATH_MAX];
  const char* tmp = getenv("TMPDIR");
  if (tmp != NULL && tmp[0] != 0) {
    if (strlen(tmp) >= sizeof(base)) return -1;
    strcpy(base, tmp);
  } else {
    size_t got = confstr(_CS_DARWIN_USER_TEMP_DIR, base, sizeof(base));
    if (got == 0 || got > sizeof(base)) return -1;
  }
  DIR* top = opendir(base);
  if (top == NULL) return -1;
  int64_t n = 0;
  size_t want = strlen(PRIVATE_DIR_PREFIX) + PRIVATE_DIR_RANDOM;
  for (struct dirent* d = readdir(top); d != NULL; d = readdir(top)) {
    if (strlen(d->d_name) != want || strncmp(d->d_name, PRIVATE_DIR_PREFIX, strlen(PRIVATE_DIR_PREFIX)) != 0) continue;
    char sub[PATH_MAX];
    if (snprintf(sub, sizeof(sub), "%s/%s", base, d->d_name) >= (int)sizeof(sub)) continue;
    DIR* inner = opendir(sub);
    if (inner == NULL) continue;
    for (struct dirent* f = readdir(inner); f != NULL; f = readdir(inner))
      if (f->d_name[0] != '.') n++;
    closedir(inner);
  }
  closedir(top);
  return n;
#else
  return 0;
#endif
}

/* The longest path the system takes, with its terminator (PATH_MAX). */
int64_t komira_udf_spike_path_max(void) { return (int64_t)PATH_MAX; }
