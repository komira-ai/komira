// The in-memory source id counter: a process-unique, never-zero id for each
// in-memory source.
//
// The counter is a process-resident static updated with relaxed atomics: it
// carries no happens-before guarantee and is only read as a total. This file
// is the only definition of this symbol. A package that needs it depends on
// komira_scan_source rather than defining its own copy.

#include <stdint.h>

static uint64_t _inmem_source_counter = 0;

// A process-unique, never-zero id for each in-memory source.
uint64_t komira_next_inmem_source_id(void) {
    return __atomic_fetch_add(&_inmem_source_counter, 1, __ATOMIC_RELAXED) + 1;
}
