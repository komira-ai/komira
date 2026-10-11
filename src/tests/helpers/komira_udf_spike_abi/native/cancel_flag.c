/*
 * The harness's cancel store: sets a call's cancel flag with a release store,
 * as the design asks of the host (komira_udf_call.cancel, section 4.4; the
 * runtime reads it with an atomic load). The host's now_ns callback calls it
 * when the call was started with cancel_during_call, so the flag is set from
 * inside the call, the first time the runtime reads the host's clock, and at
 * no time a clock or a thread decides (runtime.mojo, CallOptions).
 */
#include <stdint.h>

void komira_udf_spike_cancel_store(int32_t* flag) { __atomic_store_n(flag, 1, __ATOMIC_RELEASE); }
