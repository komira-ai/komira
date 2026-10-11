/*
 * The harness's clock and cancel store.
 *
 * komira_udf_spike_cancel_store sets a call's cancel flag with a release
 * store, as the design asks of the host (komira_udf_call.cancel, section
 * 4.4; the runtime reads it with an atomic load). The host's now_ns callback
 * calls it when the call was started with cancel_during_call, so the flag is
 * set from inside the call, the first time the runtime reads the host's
 * clock, and at no time a clock or a thread decides (runtime.mojo,
 * CallOptions).
 *
 * The clock (komira_udf_spike_clock_*) is three words the host owns:
 *   clk[0]  the virtual clock's next reading;
 *   clk[1]  the last reading now_ns returned;
 *   clk[2]  1 while a call with a future deadline runs (the virtual clock).
 * Every reading is floored at the last one returned, so now_ns is monotonic
 * (the header's "monotonic clock") across calls and modes. While virtual,
 * each read advances the clock by one step with an atomic fetch-add, so
 * concurrent readers each see their own step (every host callback is
 * thread-safe).
 */
#include <stdint.h>

#define KOMIRA_UDF_SPIKE_CLOCK_STEP_NS 1000000 /* 1 ms per virtual read */

void komira_udf_spike_cancel_store(int32_t* flag) { __atomic_store_n(flag, 1, __ATOMIC_RELEASE); }

/* Start the virtual clock at max(wall, last reading) and return that start. */
int64_t komira_udf_spike_clock_arm(int64_t* clk, int64_t wall) {
  int64_t last = __atomic_load_n(&clk[1], __ATOMIC_ACQUIRE);
  int64_t start = wall > last ? wall : last;
  __atomic_store_n(&clk[0], start, __ATOMIC_RELEASE);
  __atomic_store_n(&clk[2], 1, __ATOMIC_RELEASE);
  return start;
}

void komira_udf_spike_clock_disarm(int64_t* clk) { __atomic_store_n(&clk[2], 0, __ATOMIC_RELEASE); }

int64_t komira_udf_spike_clock_is_virtual(int64_t* clk) { return __atomic_load_n(&clk[2], __ATOMIC_ACQUIRE); }

/* One now_ns reading: the virtual clock's next step while armed, else
 * `wall`; never below the last reading returned. */
int64_t komira_udf_spike_clock_read(int64_t* clk, int64_t wall) {
  int64_t v = __atomic_load_n(&clk[2], __ATOMIC_ACQUIRE) == 1
                  ? __atomic_fetch_add(&clk[0], KOMIRA_UDF_SPIKE_CLOCK_STEP_NS, __ATOMIC_ACQ_REL)
                  : wall;
  int64_t last = __atomic_load_n(&clk[1], __ATOMIC_ACQUIRE);
  while (v > last && !__atomic_compare_exchange_n(&clk[1], &last, v, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
  }
  return v > last ? v : last;
}
