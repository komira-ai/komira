/*
 * What the native runtime's tests read about the process: the number of
 * objects the dynamic loader has mapped (dl_iterate_phdr counts the program,
 * every shared library and the vDSO). A library the native runtime dlopens
 * adds one; a library it refuses before dlopen adds none.
 */
#define _GNU_SOURCE
#include <link.h>
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
