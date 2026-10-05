// The pool-depth counter: how many executor-pool dispatches are in flight.
//
// The counter is a process-resident static updated with relaxed atomics: it
// carries no happens-before guarantee and is only read as a total. This file
// is the only definition of these symbols. A package that needs one of them
// depends on komira_concurrency rather than defining its own copy.

#include <stdint.h>

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
