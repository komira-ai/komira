/*
 * komira-test/echo, part four: the variant init (ECHO_INIT_VARIANT), built
 * into echo_variant.so. Included once, at the end of echo_runtime.c; not a
 * header of its own.
 *
 * Each variant is echo with one thing wrong, or right at an edge, in its
 * table or its describe answer, so a test can show that each of the host's
 * checks of a runtime goes off, and goes off only when it should
 * (test_harness). The variant is named by the environment variable
 * KOMIRA_UDF_ECHO_VARIANT, read at every init: the library is loaded once
 * and its one export takes no other input. (Configuration of a program is a
 * flag; a fixture inside a dlopened library has no argv.) An unset or
 * unknown name fails init with ERR_INTERNAL, so a typo in a test cannot
 * pass as a valid runtime.
 */

enum variant_id {
  V_TABLE_MAJOR_2 = 1,      /* the table says ABI major 2 */
  V_TABLE_SHORT,            /* struct_size stops before shutdown, a required entry */
  V_TABLE_WITHOUT_OPTIONAL, /* struct_size stops before memory_report (legal), feature bit clear */
  V_ANY_MAJOR,              /* init accepts a host of any ABI major */
  V_DESCRIBE_FAILS,         /* describe returns ERR_INTERNAL */
  V_PER_THREAD_GLOBAL_LOCK, /* CONTEXT_PER_THREAD with global_lock 1 (legal) */
  V_SINGLE_THREAD,          /* SINGLE_THREAD (legal) */
  V_THREADING_0,
  V_THREADING_4,
  V_NO_CPU,                 /* devices lacks CPU */
  V_WORKER_ONLY,            /* transports lacks IN_PROCESS */
  V_NATIVE,                 /* NATIVE with hosting 0 (legal) */
  V_NATIVE_EMBEDDED,        /* NATIVE with hosting EMBEDDED */
  V_MANAGED_HOSTING_0,      /* MANAGED with hosting 0 */
  V_HOST_INTERPRETER,       /* MANAGED with HOST_INTERPRETER (legal) */
  V_CLASS_0,
  V_CLASS_3,
  V_BAD_ID,                 /* a runtime id with upper case */
  V_FEATURE_WITHOUT_ENTRY,  /* MEMORY_REPORT set, memory_report NULL */
  V_ENTRY_WITHOUT_FEATURE   /* memory_report set, MEMORY_REPORT clear */
};

static const struct {
  const char* name;
  enum variant_id id;
} VARIANTS[] = {
    {"table_major_2", V_TABLE_MAJOR_2},
    {"table_short", V_TABLE_SHORT},
    {"table_without_optional", V_TABLE_WITHOUT_OPTIONAL},
    {"any_major", V_ANY_MAJOR},
    {"describe_fails", V_DESCRIBE_FAILS},
    {"per_thread_global_lock", V_PER_THREAD_GLOBAL_LOCK},
    {"single_thread", V_SINGLE_THREAD},
    {"threading_0", V_THREADING_0},
    {"threading_4", V_THREADING_4},
    {"no_cpu", V_NO_CPU},
    {"worker_only", V_WORKER_ONLY},
    {"native", V_NATIVE},
    {"native_embedded", V_NATIVE_EMBEDDED},
    {"managed_hosting_0", V_MANAGED_HOSTING_0},
    {"host_interpreter", V_HOST_INTERPRETER},
    {"class_0", V_CLASS_0},
    {"class_3", V_CLASS_3},
    {"bad_id", V_BAD_ID},
    {"feature_without_entry", V_FEATURE_WITHOUT_ENTRY},
    {"entry_without_feature", V_ENTRY_WITHOUT_FEATURE},
};

static const komira_udf_runtime TABLE_MAJOR_2 = {
    sizeof(komira_udf_runtime), 2, KOMIRA_UDF_ABI_MINOR, ECHO_ENTRIES, echo_memory_report,
};
static const komira_udf_runtime TABLE_SHORT = {
    offsetof(komira_udf_runtime, shutdown), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, ECHO_ENTRIES,
    echo_memory_report,
};
/* memory_report is set, past struct_size: a host that reads it there is
 * wrong. */
static const komira_udf_runtime TABLE_WITHOUT_OPTIONAL = {
    offsetof(komira_udf_runtime, memory_report), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, ECHO_ENTRIES,
    echo_memory_report,
};
static const komira_udf_runtime TABLE_NO_REPORT = {
    sizeof(komira_udf_runtime), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, ECHO_ENTRIES, NULL,
};

static int32_t describe_variant(const komira_udf_rt* rt, komira_udf_capabilities* c) {
  switch ((enum variant_id)rt->variant) {
    case V_TABLE_WITHOUT_OPTIONAL:
    case V_ENTRY_WITHOUT_FEATURE:
      c->features = 0;
      break;
    case V_DESCRIBE_FAILS:
      return KOMIRA_UDF_ERR_INTERNAL;
    case V_PER_THREAD_GLOBAL_LOCK:
      c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
      c->global_lock = 1;
      break;
    case V_SINGLE_THREAD:
      c->threading = KOMIRA_UDF_SINGLE_THREAD;
      break;
    case V_THREADING_0:
      c->threading = 0;
      break;
    case V_THREADING_4:
      c->threading = 4;
      break;
    case V_NO_CPU:
      c->devices = 0;
      break;
    case V_WORKER_ONLY:
      c->transports = KOMIRA_UDF_TRANSPORT_WORKER;
      break;
    case V_NATIVE:
      c->udf_class = KOMIRA_UDF_CLASS_NATIVE;
      c->hosting = KOMIRA_UDF_HOSTING_NONE;
      break;
    case V_NATIVE_EMBEDDED:
      c->udf_class = KOMIRA_UDF_CLASS_NATIVE;
      break;
    case V_MANAGED_HOSTING_0:
      c->hosting = KOMIRA_UDF_HOSTING_NONE;
      break;
    case V_HOST_INTERPRETER:
      c->hosting = KOMIRA_UDF_HOSTING_HOST_INTERPRETER;
      break;
    case V_CLASS_0:
      c->udf_class = 0;
      break;
    case V_CLASS_3:
      c->udf_class = 3;
      break;
    case V_BAD_ID:
      c->runtime_id = "Komira-test/echo";
      break;
    default:
      break;
  }
  return KOMIRA_UDF_OK;
}

const komira_udf_runtime* ECHO_INIT_VARIANT(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  const char* name = getenv("KOMIRA_UDF_ECHO_VARIANT");
  int id = 0;
  for (size_t i = 0; name != NULL && i < sizeof(VARIANTS) / sizeof(VARIANTS[0]); i++)
    if (strcmp(VARIANTS[i].name, name) == 0) id = VARIANTS[i].id;
  if (id == 0) {
    fail(host, e, KOMIRA_UDF_ERR_INTERNAL, "KOMIRA_UDF_ECHO_VARIANT names no variant", -1);
    return NULL;
  }
  komira_udf_rt* r = new_rt(host, e, 0, id == V_ANY_MAJOR);
  if (r == NULL) return NULL;
  r->variant = id;
  *rt = r;
  switch (id) {
    case V_TABLE_MAJOR_2:
      return &TABLE_MAJOR_2;
    case V_TABLE_SHORT:
      return &TABLE_SHORT;
    case V_TABLE_WITHOUT_OPTIONAL:
      return &TABLE_WITHOUT_OPTIONAL;
    case V_FEATURE_WITHOUT_ENTRY:
      return &TABLE_NO_REPORT;
    default:
      return &TABLE;
  }
}
