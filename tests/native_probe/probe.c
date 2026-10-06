/* A symbol no other library defines: the native code the probe links. */
#include <stdint.h>

int64_t komira_probe_answer(void) { return 42; }
