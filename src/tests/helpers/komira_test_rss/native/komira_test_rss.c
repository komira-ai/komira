/*
 * The process's resident and virtual sizes, in KiB, for the memory-growth
 * checks of welded tests, on Linux and on macOS.
 *
 *   komira_test_rss_resident_kib()      the resident set now
 *   komira_test_rss_peak_resident_kib() the largest resident set so far
 *   komira_test_rss_peak_virtual_kib()  the largest virtual size so far
 *
 * Linux reads `VmRSS:`, `VmHWM:` and `VmPeak:` of /proc/self/status (the
 * kernel writes them in kB). macOS has no /proc: task_info's
 * MACH_TASK_BASIC_INFO gives `resident_size` and `resident_size_max` in bytes,
 * divided here by 1024, and keeps no peak of the virtual size, so the third
 * returns KOMIRA_TEST_RSS_NOT_KEPT (-2) there.
 *
 * Each returns -1 when the value cannot be read (the file does not open, the
 * line is missing, task_info fails). No pointer crosses the boundary: every
 * function takes nothing and returns a scalar.
 */

#if defined(__APPLE__)

#include <mach/mach.h>

static long long task_kib(int peak) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return -1;
  }
  return (long long)((peak ? info.resident_size_max : info.resident_size) /
                     1024);
}

long long komira_test_rss_resident_kib(void) { return task_kib(0); }
long long komira_test_rss_peak_resident_kib(void) { return task_kib(1); }
long long komira_test_rss_peak_virtual_kib(void) { return -2; }

#else

#include <stdio.h>
#include <string.h>

/* The `<key> <n> kB` value of /proc/self/status, or -1. */
static long long status_kib(const char *key) {
  FILE *f = fopen("/proc/self/status", "r");
  if (f == NULL) {
    return -1;
  }
  char line[256];
  size_t n = strlen(key);
  long long v = -1;
  while (fgets(line, sizeof line, f) != NULL) {
    if (strncmp(line, key, n) == 0) {
      if (sscanf(line + n, "%lld", &v) != 1) {
        v = -1;
      }
      break;
    }
  }
  fclose(f);
  return v;
}

long long komira_test_rss_resident_kib(void) { return status_kib("VmRSS:"); }
long long komira_test_rss_peak_resident_kib(void) {
  return status_kib("VmHWM:");
}
long long komira_test_rss_peak_virtual_kib(void) {
  return status_kib("VmPeak:");
}

#endif
