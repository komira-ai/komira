/*
 * zygote.c: generations of the zygote and the control channel.
 *
 * A generation is one zygote process, started with posix_spawn (never fork:
 * the engine is multi-threaded) the first time a load needs one, and the
 * control socket it answers on. The library never installs a signal
 * handler, never touches SIGCHLD and never waits on -1: it waits only on a
 * zygote's own pid, after its socket ended or after SHUTDOWN.
 *
 * The zygote's environment is exactly the one in spawn(); its descriptor 3
 * is its end of the control socket, 0 is /dev/null, 1 and 2 are the
 * engine's, and every other descriptor is closed. Its working directory is
 * the cwd directory of a fresh directory made under the `scratch` option.
 *
 * EXIT reports: the zygote sends one, unasked, for each worker it reaps. They
 * are read wherever the control channel is read: inside any request, by
 * udfpy_ctl_drain before a LOAD or a FORK, and by udfpy_await_exit, which a
 * context whose worker ended uses to learn how it ended. If the zygote's
 * socket ends first, the generation is dead: the zygote is reaped (its own
 * pid only; ECHILD, when something else in the process reaped it, leaves its
 * status unknown) and the generation retired.
 *
 * Every function here runs with rt->zy_mu held, except udfpy_trace.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "udfpy.h"

/* ---- trace --------------------------------------------------------------------- */

void udfpy_trace(udfpy_rt* rt, const char* fmt, ...) {
  if (rt->trace_fd < 0) return;
  char line[1200];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(line, sizeof(line) - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if ((size_t)n > sizeof(line) - 2) n = (int)sizeof(line) - 2;
  line[n++] = '\n';
  ssize_t w = write(rt->trace_fd, line, (size_t)n);
  (void)w; /* a trace that cannot be written is lost; the call goes on */
}

/* ---- the generation list ---------------------------------------------------------- */

static udfpy_gen* gen_new(udfpy_rt* rt) {
  if (rt->n_gens == rt->cap_gens) {
    int cap = rt->cap_gens ? 2 * rt->cap_gens : 4;
    udfpy_gen** p = (udfpy_gen**)realloc(rt->gens, (size_t)cap * sizeof(*p));
    if (p == NULL) return NULL;
    rt->gens = p;
    rt->cap_gens = cap;
  }
  udfpy_gen* g = (udfpy_gen*)calloc(1, sizeof(*g));
  if (g == NULL) return NULL;
  g->number = ++rt->next_gen;
  g->pid = -1;
  g->sock = -1;
  rt->gens[rt->n_gens++] = g;
  return g;
}

void udfpy_gens_free(udfpy_rt* rt) {
  for (int i = 0; i < rt->n_gens; i++) free(rt->gens[i]);
  free(rt->gens);
  rt->gens = NULL;
  rt->n_gens = rt->cap_gens = 0;
  rt->cur = NULL;
}

/* ---- reaping and ending ---------------------------------------------------------------- */

/* Wait for the zygote's own pid and record how it ended. */
static void reap(udfpy_gen* g) {
  if (g->pid <= 0 || g->reaped) return;
  int st = 0;
  pid_t got;
  do {
    got = waitpid(g->pid, &st, 0);
  } while (got < 0 && errno == EINTR);
  g->reaped = 1;
  g->pid = -1;
  g->exit_how = 0;
  g->exit_value = -1;
  if (got > 0 && WIFEXITED(st)) {
    g->exit_value = WEXITSTATUS(st);
  } else if (got > 0 && WIFSIGNALED(st)) {
    g->exit_how = 1;
    g->exit_value = WTERMSIG(st);
  }
}


static const char* op_name(uint32_t op) {
  switch (op) {
    case UDFPY_OP_HELLO: return "HELLO";
    case UDFPY_OP_LOAD: return "LOAD";
    case UDFPY_OP_UNLOAD: return "UNLOAD";
    case UDFPY_OP_SHUTDOWN: return "SHUTDOWN";
    case UDFPY_OP_FORK: return "FORK";
    default: return "a request";
  }
}

/* An EXIT message: a worker the zygote reaped. */
static void record_exit(udfpy_rt* rt, udfpy_gen* g, const udfpy_msg* m) {
  if (m->len < 20) return;
  uint64_t ctx;
  uint32_t pid;
  int32_t how, value;
  memcpy(&ctx, m->payload, 8);
  memcpy(&pid, m->payload + 8, 4);
  memcpy(&how, m->payload + 12, 4);
  memcpy(&value, m->payload + 16, 4);
  for (int i = 0; i < rt->n_ctxs; i++)
    if (rt->ctxs[i]->id == ctx && rt->ctxs[i]->gen == g) {
      rt->ctxs[i]->exit_how = how;
      rt->ctxs[i]->exit_value = value;
      __atomic_store_n(&rt->ctxs[i]->exit_known, 1, __ATOMIC_RELEASE);
    }
  udfpy_trace(rt, "exit gen=%d ctx=%llu pid=%u how=%s value=%d", g->number, (unsigned long long)ctx, pid,
              how == 0 ? "exited" : "signalled", value);
}

/* ---- retire and shut down ------------------------------------------------------------------ */

/* The zygote's socket ended or broke: close it, reap, retire. */
static void mark_dead(udfpy_rt* rt, udfpy_gen* g) {
  __atomic_store_n(&g->dead, 1, __ATOMIC_RELEASE);
  if (g->sock >= 0) close(g->sock);
  g->sock = -1;
  reap(g);
  udfpy_gen_retire(rt, g);
}

void udfpy_gen_shutdown(udfpy_rt* rt, udfpy_gen* g) {
  if (g->shut) return;
  int asked = 0;
  if (!g->dead && g->sock >= 0) {
    udfpy_msg r;
    if (udfpy_ctl_request(rt, g, UDFPY_OP_SHUTDOWN, 0, 0, NULL, 0, NULL, 0, &r, NULL) == KOMIRA_UDF_OK) {
      udfpy_msg_free(&r);
      asked = 1;
      /* Read to the end of the stream: EXIT messages sent while the zygote
       * stopped its workers are recorded. */
      const char* why = NULL;
      udfpy_msg m;
      while (udfpy_recv(g->sock, &m, &why) == 0) {
        if (m.op == UDFPY_OP_EXIT) record_exit(rt, g, &m);
        udfpy_msg_free(&m);
      }
    }
  }
  if (g->shut) return; /* a failed request ended the generation (mark_dead) */
  if (g->sock >= 0) close(g->sock);
  g->sock = -1;
  if (g->pid > 0 && !g->reaped) {
    if (!asked) kill(g->pid, SIGKILL);
    reap(g);
  }
  g->shut = 1;
  g->retired = 1;
  if (rt->cur == g) rt->cur = NULL;
  udfpy_trace(rt, "shutdown gen=%d pid=%d status=%s %d", g->number, (int)g->spawn_pid,
              g->exit_how == 0 ? "exited" : "signalled", g->exit_value);
}

void udfpy_gen_retire(udfpy_rt* rt, udfpy_gen* g) {
  if (g->retired) return;
  g->retired = 1;
  if (rt->cur == g) rt->cur = NULL;
  udfpy_trace(rt, "retire gen=%d", g->number);
  if (g->open_ctx == 0) udfpy_gen_shutdown(rt, g);
}

/* ---- the control channel ---------------------------------------------------------------------- */

static int32_t ended(udfpy_rt* rt, udfpy_gen* g, uint32_t op, komira_udf_error* err) {
  char how[48];
  udfpy_how_text(g->exit_how, g->exit_value, how, sizeof(how));
  if (!g->helloed)
    return udfpy_fail(err, KOMIRA_UDF_ERR_LOAD, -1, "the interpreter '%s' ended before HELLO (%s)", rt->opt.interpreter,
                      how);
  return udfpy_fail(err, KOMIRA_UDF_ERR_LOAD, -1, "the interpreter '%s' ended during %s (%s)", rt->opt.interpreter,
                    op_name(op), how);
}

int32_t udfpy_ctl_request(udfpy_rt* rt, udfpy_gen* g, uint32_t op, uint32_t flags, uint64_t handle,
                          const uint8_t* body, size_t body_len, const int* fds, int nfds, udfpy_msg* reply,
                          komira_udf_error* err) {
  memset(reply, 0, sizeof(*reply));
  if (g->dead || g->sock < 0) return ended(rt, g, op, err);
  uint64_t id = ++g->next_request;
  if (udfpy_send(g->sock, op, id, flags, handle, 0, 0, body, body_len, fds, nfds) != 0) {
    mark_dead(rt, g);
    return ended(rt, g, op, err);
  }
  for (;;) {
    udfpy_msg m;
    const char* why = "an unexpected message";
    int rc = udfpy_recv(g->sock, &m, &why);
    if (rc == -1) {
      mark_dead(rt, g);
      return ended(rt, g, op, err);
    }
    if (rc == 0 && m.op == UDFPY_OP_EXIT) {
      record_exit(rt, g, &m);
      udfpy_msg_free(&m);
      continue;
    }
    if (rc == 0 && (m.op == UDFPY_OP_OK || m.op == UDFPY_OP_ERROR) && m.request_id == id) {
      g->helloed = g->helloed || op == UDFPY_OP_HELLO;
      *reply = m;
      return KOMIRA_UDF_OK;
    }
    if (rc == 0) {
      udfpy_msg_free(&m);
      why = "a reply that answers no request";
    }
    if (g->pid > 0) kill(g->pid, SIGKILL);
    mark_dead(rt, g);
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the zygote's reply broke the framing: %s", why);
  }
}

/* One message read while no request is pending: an EXIT is recorded; the
 * end of the socket, or anything else, ends the generation. 0 while the
 * generation lives. */
static int read_unasked(udfpy_rt* rt, udfpy_gen* g) {
  udfpy_msg m;
  const char* why = NULL;
  int rc = udfpy_recv(g->sock, &m, &why);
  if (rc == 0 && m.op == UDFPY_OP_EXIT) {
    record_exit(rt, g, &m);
    udfpy_msg_free(&m);
    return 0;
  }
  if (rc == 0) udfpy_msg_free(&m);
  if (rc != -1 && g->pid > 0) kill(g->pid, SIGKILL); /* it broke the framing */
  mark_dead(rt, g);
  return -1;
}

void udfpy_ctl_drain(udfpy_rt* rt, udfpy_gen* g) {
  while (!g->dead && g->sock >= 0) {
    struct pollfd p = {g->sock, POLLIN, 0};
    if (poll(&p, 1, 0) <= 0) return;
    if (read_unasked(rt, g) != 0) return;
  }
}

void udfpy_await_exit(udfpy_rt* rt, komira_udf_context_t* c) {
  udfpy_gen* g = c->gen;
  while (!c->exit_known && !g->dead && g->sock >= 0)
    if (read_unasked(rt, g) != 0) return;
}

/* ---- spawn -------------------------------------------------------------------------------------- */

/* A close-on-exec descriptor numbered above 4, so the dup2 to 3 in the child
 * clears close-on-exec on the copy. */
static int high_fd(int fd) {
  if (fd > 4) return fd;
  int h = fcntl(fd, F_DUPFD_CLOEXEC, 10);
  close(fd);
  return h;
}

static void remove_dirs(const char* dir) {
  const char* parts[3] = {"home", "tmp", "cwd"};
  char p[4200];
  for (int i = 0; i < 3; i++) {
    snprintf(p, sizeof(p), "%s/%s", dir, parts[i]);
    rmdir(p);
  }
  rmdir(dir);
}

/* The scratch directory of one zygote: <scratch>/zygote-XXXXXX with home/,
 * tmp/ and cwd/ in it, all mode 0700. */
static int32_t make_dirs(udfpy_rt* rt, char* dir, size_t n, komira_udf_error* err) {
  snprintf(dir, n, "%s/zygote-XXXXXX", rt->opt.scratch);
  if (mkdtemp(dir) == NULL)
    return udfpy_fail(err, KOMIRA_UDF_ERR_LOAD, -1, "could not make a scratch directory under '%s': %s",
                      rt->opt.scratch, strerror(errno));
  const char* parts[3] = {"home", "tmp", "cwd"};
  char p[4200];
  for (int i = 0; i < 3; i++) {
    snprintf(p, sizeof(p), "%s/%s", dir, parts[i]);
    if (mkdir(p, 0700) != 0) {
      int e = errno;
      remove_dirs(dir);
      return udfpy_fail(err, KOMIRA_UDF_ERR_LOAD, -1, "could not make '%s': %s", p, strerror(e));
    }
  }
  return KOMIRA_UDF_OK;
}

static int spawn(udfpy_rt* rt, udfpy_gen* g, const char* dir, komira_udf_error* err) {
  int sv[2];
  if (udfpy_socketpair(sv) != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "socketpair: %s", strerror(errno));
  int child = high_fd(sv[1]);
  if (child < 0) {
    close(sv[0]);
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "fcntl: %s", strerror(errno));
  }
  char cwd[4200], home[4200], tmp[4200];
  snprintf(cwd, sizeof(cwd), "%s/cwd", dir);
  snprintf(home, sizeof(home), "HOME=%s/home", dir);
  snprintf(tmp, sizeof(tmp), "TMPDIR=%s/tmp", dir);
  char* envp[] = {"OMP_NUM_THREADS=1", "OPENBLAS_NUM_THREADS=1", "MKL_NUM_THREADS=1", "VECLIB_MAXIMUM_THREADS=1",
                  "NUMEXPR_NUM_THREADS=1",
                  "JE_ARROW_MALLOC_CONF=background_thread:false", "LC_ALL=C", "TZ=UTC", home, tmp, "PATH=/usr/bin:/bin", NULL};
  const char* argv[16 + 2 * UDFPY_MAX_SYS_PATH];
  int a = 0;
  argv[a++] = rt->opt.interpreter;
  argv[a++] = "-I";
  argv[a++] = "-X";
  argv[a++] = "utf8";
  argv[a++] = rt->opt.zygote;
  argv[a++] = "--control-fd";
  argv[a++] = "3";
  argv[a++] = "--wire-version";
  argv[a++] = "3";
  argv[a++] = "--scratch";
  argv[a++] = dir;
  for (int i = 0; i < rt->opt.n_sys_path; i++) {
    argv[a++] = "--sys-path";
    argv[a++] = rt->opt.sys_path[i];
  }
  argv[a] = NULL;
  posix_spawn_file_actions_t fa;
  posix_spawnattr_t attr;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, child, 3);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addchdir_np(&fa, cwd);
#ifdef __APPLE__
  /* No closefrom action on macOS: every descriptor is closed but 0, 1, 2
   * and 3 (POSIX_SPAWN_CLOEXEC_DEFAULT keeps those the actions make). */
  posix_spawn_file_actions_addinherit_np(&fa, 1);
  posix_spawn_file_actions_addinherit_np(&fa, 2);
#else
  posix_spawn_file_actions_addclosefrom_np(&fa, 4);
#endif
  posix_spawnattr_init(&attr);
  sigset_t none, all;
  sigemptyset(&none);
  sigfillset(&all);
  posix_spawnattr_setsigmask(&attr, &none);
  posix_spawnattr_setsigdefault(&attr, &all);
  posix_spawnattr_setpgroup(&attr, 0);
#ifdef __APPLE__
  posix_spawnattr_setflags(&attr,
                           POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
#else
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP);
#endif
  pid_t pid = -1;
  int rc = posix_spawn(&pid, rt->opt.interpreter, &fa, &attr, (char* const*)argv, envp);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&attr);
  close(child);
  if (rc != 0) {
    close(sv[0]);
    return udfpy_fail(err, KOMIRA_UDF_ERR_LOAD, -1, "could not start the interpreter '%s': %s", rt->opt.interpreter,
                      strerror(rc));
  }
  g->pid = pid;
  g->spawn_pid = pid;
  g->sock = sv[0];
  udfpy_trace(rt, "spawn gen=%d pid=%d", g->number, (int)pid);
  return KOMIRA_UDF_OK;
}

/* ---- HELLO ------------------------------------------------------------------------------------------ */

typedef struct rdcur {
  const uint8_t* p;
  size_t n, at;
  int bad;
} rdcur;

static uint32_t cu32(rdcur* c) {
  uint32_t v = 0;
  if (c->n - c->at < 4) {
    c->bad = 1;
    return 0;
  }
  memcpy(&v, c->p + c->at, 4);
  c->at += 4;
  return v;
}

/* A str into `out` (NUL-terminated, cut to `cap`). */
static void cstr(rdcur* c, char* out, size_t cap) {
  uint32_t n = cu32(c);
  if (c->bad || n > c->n - c->at) {
    c->bad = 1;
    out[0] = 0;
    return;
  }
  size_t k = n < cap - 1 ? n : cap - 1;
  memcpy(out, c->p + c->at, k);
  out[k] = 0;
  c->at += n;
}

static int32_t hello(udfpy_rt* rt, udfpy_gen* g, komira_udf_error* err) {
  uint32_t body[3] = {UDFPY_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR};
  udfpy_msg r;
  int32_t st = udfpy_ctl_request(rt, g, UDFPY_OP_HELLO, 0, 0, (const uint8_t*)body, sizeof(body), NULL, 0, &r, err);
  if (st != KOMIRA_UDF_OK) return st;
  st = udfpy_reply_status(&r, err);
  if (st != KOMIRA_UDF_OK) {
    udfpy_msg_free(&r);
    return st;
  }
  rdcur c = {r.payload, r.len, 0, 0};
  uint32_t wire = cu32(&c), pid = cu32(&c), ft = cu32(&c);
  char impl[64], tag[64], magic[64];
  cstr(&c, impl, sizeof(impl));
  cstr(&c, tag, sizeof(tag));
  cstr(&c, magic, sizeof(magic));
  int bad = c.bad;
  udfpy_msg_free(&r);
  if (bad) return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the zygote's HELLO reply is malformed");
  char abi[64] = "";
  if (strncmp(tag, "cpython-", 8) == 0)
    snprintf(abi, sizeof(abi), "cp%s", tag + 8);
  else
    snprintf(abi, sizeof(abi), "%s", tag);
  udfpy_trace(rt, "hello gen=%d pid=%u impl=%s tag=%s free_threaded=%u", g->number, pid, impl, abi, ft);
  if (wire != UDFPY_WIRE_VERSION)
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the zygote speaks wire version %u, this runtime %u", wire,
                      UDFPY_WIRE_VERSION);
  if (strcmp(impl, "cpython") != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "'%s' is not CPython; Python UDFs run on CPython only", impl);
  if (ft != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "a free-threaded CPython is not a Python UDF mode");
  if (strcmp(abi, rt->opt.abi) != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "the interpreter's tag %s differs from the runtime's abi %s", abi,
                      rt->opt.abi);
  return KOMIRA_UDF_OK;
}

int32_t udfpy_gen_spawn(udfpy_rt* rt, udfpy_gen** out, komira_udf_error* err) {
  *out = NULL;
  char dir[4096];
  int32_t rc = make_dirs(rt, dir, sizeof(dir), err);
  if (rc != KOMIRA_UDF_OK) return rc;
  udfpy_gen* g = gen_new(rt);
  if (g == NULL) {
    remove_dirs(dir);
    return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a generation");
  }
  rc = spawn(rt, g, dir, err);
  if (rc != KOMIRA_UDF_OK) {
    g->shut = g->retired = g->dead = 1;
    remove_dirs(dir);
    return rc;
  }
  rc = hello(rt, g, err);
  if (rc != KOMIRA_UDF_OK) {
    udfpy_gen_retire(rt, g);
    udfpy_gen_shutdown(rt, g);
    return rc;
  }
  rt->cur = g;
  *out = g;
  return KOMIRA_UDF_OK;
}
