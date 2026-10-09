/*
 * The harness's cancel timer: sets a call's cancel flag from another thread
 * while the call runs, as an engine cancelling a long call does
 * (komira_udf_call.cancel). Written in C so that no Mojo code runs on a
 * thread the Mojo runtime did not create.
 *
 * The flag is set once the call has started, with no clock in the test: the
 * host's now_ns callback counts its calls through
 * komira_udf_spike_clock_read, and the timer's thread waits until that count
 * moves past its value when the timer started (the runtime has read the
 * host's clock inside the call), then stores 1 into the flag with release
 * order. komira_udf_spike_cancel_join stops a thread that is still waiting
 * (a call that never read the clock is never cancelled), waits for it and
 * frees the timer. The caller keeps `flag` and `reads` alive until the join
 * returns.
 */
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

struct cancel_timer {
  pthread_t thread;
  int32_t* flag;
  const int64_t* reads;
  int64_t base;
  int32_t stop;
};

/* One host clock read: called by the host's now_ns on the calling thread. */
void komira_udf_spike_clock_read(int64_t* reads) { __atomic_add_fetch(reads, 1, __ATOMIC_RELEASE); }

static void* run(void* arg) {
  struct cancel_timer* t = (struct cancel_timer*)arg;
  while (!__atomic_load_n(&t->stop, __ATOMIC_ACQUIRE)) {
    if (__atomic_load_n(t->reads, __ATOMIC_ACQUIRE) != t->base) {
      __atomic_store_n(t->flag, 1, __ATOMIC_RELEASE);
      return NULL;
    }
    struct timespec left = {0, 50000};
    while (nanosleep(&left, &left) != 0 && errno == EINTR) {
    }
  }
  return NULL;
}

/* The timer, or NULL when no thread could be started (the flag is then
 * never set). Called on the calling thread before the call. */
void* komira_udf_spike_cancel_on_clock_read(int32_t* flag, const int64_t* reads) {
  struct cancel_timer* t = (struct cancel_timer*)malloc(sizeof(*t));
  if (t == NULL) return NULL;
  t->flag = flag;
  t->reads = reads;
  t->base = __atomic_load_n(reads, __ATOMIC_ACQUIRE);
  t->stop = 0;
  if (pthread_create(&t->thread, NULL, run, t) != 0) {
    free(t);
    return NULL;
  }
  return t;
}

void komira_udf_spike_cancel_join(void* timer) {
  struct cancel_timer* t = (struct cancel_timer*)timer;
  if (t == NULL) return;
  __atomic_store_n(&t->stop, 1, __ATOMIC_RELEASE);
  pthread_join(t->thread, NULL);
  free(t);
}
