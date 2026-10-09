/*
 * The harness's cancel timer: sets a call's cancel flag from another thread
 * while the call runs, as an engine cancelling a long call does
 * (komira_udf_call.cancel). Written in C so that no Mojo code runs on a
 * thread the Mojo runtime did not create.
 *
 * komira_udf_spike_cancel_after starts a thread that sleeps `delay_ns`, then
 * stores 1 into `*flag` with release order. komira_udf_spike_cancel_join
 * waits for that thread and frees the timer. The caller keeps `flag` alive
 * until the join returns.
 */
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

struct cancel_timer {
  pthread_t thread;
  int32_t* flag;
  int64_t delay_ns;
};

static void* run(void* arg) {
  struct cancel_timer* t = (struct cancel_timer*)arg;
  struct timespec left = {(time_t)(t->delay_ns / 1000000000), (long)(t->delay_ns % 1000000000)};
  while (nanosleep(&left, &left) != 0 && errno == EINTR) {
  }
  __atomic_store_n(t->flag, 1, __ATOMIC_RELEASE);
  return NULL;
}

/* The timer, or NULL when no thread could be started (the flag is then
 * never set). */
void* komira_udf_spike_cancel_after(int32_t* flag, int64_t delay_ns) {
  struct cancel_timer* t = (struct cancel_timer*)malloc(sizeof(*t));
  if (t == NULL) return NULL;
  t->flag = flag;
  t->delay_ns = delay_ns < 0 ? 0 : delay_ns;
  if (pthread_create(&t->thread, NULL, run, t) != 0) {
    free(t);
    return NULL;
  }
  return t;
}

void komira_udf_spike_cancel_join(void* timer) {
  struct cancel_timer* t = (struct cancel_timer*)timer;
  if (t == NULL) return;
  pthread_join(t->thread, NULL);
  free(t);
}
