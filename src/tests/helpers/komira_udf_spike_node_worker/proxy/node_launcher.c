/*
 * node_launcher.c: the init of node_worker.so, the runtime library the
 * engine loads for komira-test/node: the generic worker proxy (proxy.c) with
 * the launcher of this runtime, `node` running the worker script (design
 * section 4.1: "Each runtime's manifest names its launcher"). Test-only
 * spike code.
 *
 * The runtime finds everything beside its own library file, in
 * node_worker/: node/ (the pinned Node.js), lib/ (the C++ runtime `node`
 * loads), worker/ (the worker script and its modules), node_modules/
 * (apache-arrow and its dependencies, which the worker imports and the
 * user's bundle does not carry) and code/ (the user bundles, standing in for
 * the code layer). `--preserve-symlinks` keeps module resolution in that
 * directory when the files are links into a build tree.
 *
 * Two inits, each the target of one shared library's export
 * komira_udf_runtime_init_v1 (refrt/): kudfw_node_init_v1 for
 * node_worker.so, and kudfw_node_corrupt_init_v1 for node_worker_corrupt.so,
 * whose workers run with --corrupt-output (worker/worker.mjs) for the test of
 * the proxy's validation of worker replies. The C library cannot define the
 * export itself: the one-definition gate links every C library under src/
 * into one binary, where echo's forwarders define it too.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "kudfw.h"

static pthread_once_t once = PTHREAD_ONCE_INIT;
static char node_path[PATH_MAX], worker_path[PATH_MAX], code_dir[PATH_MAX];
static char env_lib[PATH_MAX + 32], env_home[PATH_MAX + 16], env_tmp[PATH_MAX + 16];
static int resolved;

static void resolve(void) {
  Dl_info info;
  if (dladdr((void*)&resolve, &info) == 0 || info.dli_fname == NULL) return;
  char dir[PATH_MAX];
  if (info.dli_fname[0] == '/') {
    snprintf(dir, sizeof(dir), "%s", info.dli_fname);
  } else {
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) return;
    snprintf(dir, sizeof(dir), "%s/%s", cwd, info.dli_fname);
  }
  char* slash = strrchr(dir, '/');
  if (slash == NULL) return;
  *slash = 0;
  snprintf(node_path, sizeof(node_path), "%s/node_worker/node/bin/node", dir);
  snprintf(worker_path, sizeof(worker_path), "%s/node_worker/worker/worker.mjs", dir);
  snprintf(code_dir, sizeof(code_dir), "%s/node_worker/code", dir);
  snprintf(env_lib, sizeof(env_lib), "LD_LIBRARY_PATH=%s/node_worker/lib", dir);
  const char* tmp = getenv("TMPDIR");
  snprintf(env_home, sizeof(env_home), "HOME=%s", tmp != NULL ? tmp : "/tmp");
  snprintf(env_tmp, sizeof(env_tmp), "TMPDIR=%s", tmp != NULL ? tmp : "/tmp");
  resolved = 1;
}

static const komira_udf_runtime* init(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* err,
                                      int corrupt) {
  pthread_once(&once, resolve);
  if (!resolved) {
    *rt = NULL;
    kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the runtime could not find its own library file");
    return NULL;
  }
  kudfw_launcher l;
  memset(&l, 0, sizeof(l));
  int a = 0;
  l.argv[a++] = node_path;
  l.argv[a++] = "--preserve-symlinks";
  l.argv[a++] = "--preserve-symlinks-main";
  l.argv[a++] = "--disable-warning=ExperimentalWarning";
  l.argv[a++] = worker_path;
  l.argv[a++] = "--code-dir";
  l.argv[a++] = code_dir;
  if (corrupt) l.argv[a++] = "--corrupt-output";
  l.argv[a] = NULL;
  int e = 0;
  l.envp[e++] = env_lib;
  l.envp[e++] = env_home;
  l.envp[e++] = env_tmp;
  l.envp[e++] = "LC_ALL=C";
  l.envp[e++] = "TZ=UTC0";
  l.envp[e] = NULL;
  return kudfw_proxy_init(host, rt, err, &l);
}

const komira_udf_runtime* kudfw_node_init_v1(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* err) {
  return init(host, rt, err, 0);
}

const komira_udf_runtime* kudfw_node_corrupt_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                     komira_udf_error* err) {
  return init(host, rt, err, 1);
}
