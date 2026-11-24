/*
 * types.c: the bound Arrow types of the runtime. A C Data schema is read into
 * a pre-order array of udfpy_type nodes (udfpy.h), each node holding the kind,
 * the widths and parameters its format string names, and the index after its
 * subtree. The read is pure: it allocates nothing and reads only the schema,
 * which the host owns. Every format the runtime does not carry is refused
 * with the text of README "Types", naming the argument and the child path.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "udfpy.h"

/* The longest path: a column name, then ".name" for each further level. */
#define PATH_MAX_BYTES (UDFPY_MAX_NAME + (UDFPY_MAX_DEPTH + 1) * UDFPY_MAX_NAME + 16)

typedef struct ctx {
  udfpy_schema* out;
  char* why;
  size_t why_n;
  char path[PATH_MAX_BYTES];
  size_t plen;
} ctx;

static int refuse(ctx* c, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static int refuse(ctx* c, const char* fmt, ...) {
  if (c->why != NULL && c->why_n > 0) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(c->why, c->why_n, fmt, ap);
    va_end(ap);
  }
  return -1;
}

static void path_set(ctx* c, const char* text) {
  int n = snprintf(c->path, sizeof(c->path), "%.*s", UDFPY_MAX_NAME - 1, text);
  c->plen = n > 0 ? (size_t)n : 0;
}

static void path_push(ctx* c, const char* name) {
  int n = snprintf(c->path + c->plen, sizeof(c->path) - c->plen, ".%.*s", UDFPY_MAX_NAME - 1, name);
  if (n > 0) c->plen += (size_t)n;
  if (c->plen >= sizeof(c->path)) c->plen = sizeof(c->path) - 1;
}

static void path_pop(ctx* c, size_t to) {
  c->plen = to;
  c->path[to] = 0;
}

/* A decimal number of at most three digits without a leading zero (but 0
 * itself), read at *p. */
static int small_uint(const char** p, int* out) {
  const char* s = *p;
  int v = 0, n = 0;
  while (s[n] >= '0' && s[n] <= '9') {
    if (n == 3) return 0;
    v = v * 10 + (s[n] - '0');
    n++;
  }
  if (n == 0 || (n > 1 && s[0] == '0')) return 0;
  *out = v;
  *p = s + n;
  return 1;
}

/* "d:P,S" or "d:P,S,128" with 1 <= P <= 38 and 0 <= S <= P. */
static int decimal_format(const char* f, int* precision, int* scale) {
  if (f[0] != 'd' || f[1] != ':') return 0;
  const char* p = f + 2;
  int pr = 0, sc = 0;
  if (!small_uint(&p, &pr) || *p++ != ',' || !small_uint(&p, &sc)) return 0;
  if (*p == ',') {
    if (strcmp(p, ",128") != 0) return 0;
    p += 4;
  }
  if (*p != 0 || pr < 1 || pr > 38 || sc > pr) return 0;
  *precision = pr;
  *scale = sc;
  return 1;
}

/* Fill the kind-specific fields of `t` from format `f`; 0 when the format is
 * not one the runtime carries. A timestamp's zone is left for the caller. */
static int parse_format(const char* f, udfpy_type* t) {
  if (f[0] == 0) return 0;
  if (f[1] == 0) {
    switch (f[0]) {
      case 'b': t->kind = UDFPY_K_BOOL; t->width = 0; return 1;
      case 'c': t->kind = UDFPY_K_INT; t->width = 1; return 1;
      case 's': t->kind = UDFPY_K_INT; t->width = 2; return 1;
      case 'i': t->kind = UDFPY_K_INT; t->width = 4; return 1;
      case 'l': t->kind = UDFPY_K_INT; t->width = 8; return 1;
      case 'f': t->kind = UDFPY_K_FLOAT; t->width = 4; return 1;
      case 'g': t->kind = UDFPY_K_FLOAT; t->width = 8; return 1;
      case 'u': t->kind = UDFPY_K_UTF8; t->width = 4; return 1;
      case 'U': t->kind = UDFPY_K_UTF8; t->width = 8; return 1;
      case 'z': t->kind = UDFPY_K_BINARY; t->width = 4; return 1;
      case 'Z': t->kind = UDFPY_K_BINARY; t->width = 8; return 1;
      default: return 0;
    }
  }
  if (strcmp(f, "tdD") == 0) {
    t->kind = UDFPY_K_DATE32;
    t->width = 4;
    return 1;
  }
  if (f[0] == 't' && f[1] == 's' && f[2] != 0 && f[3] == ':') {
    const char* units = "smun";
    const char* u = strchr(units, f[2]);
    if (u == NULL) return 0;
    t->kind = UDFPY_K_TIMESTAMP;
    t->width = 8;
    t->unit = (uint8_t)(u - units);
    return 1;
  }
  if (f[0] == 'd') {
    int pr = 0, sc = 0;
    if (!decimal_format(f, &pr, &sc)) return 0;
    t->kind = UDFPY_K_DECIMAL;
    t->width = 16;
    t->precision = pr;
    t->scale = sc;
    return 1;
  }
  if (strcmp(f, "+l") == 0 || strcmp(f, "+L") == 0) {
    t->kind = UDFPY_K_LIST;
    t->width = f[1] == 'l' ? 4 : 8;
    return 1;
  }
  if (strcmp(f, "+s") == 0) {
    t->kind = UDFPY_K_STRUCT;
    return 1;
  }
  return 0;
}

static int read_node(ctx* c, const struct ArrowSchema* s, int depth) {
  udfpy_schema* out = c->out;
  const char* fmt = s != NULL && s->format != NULL ? s->format : "";
  if (depth > UDFPY_MAX_DEPTH)
    return refuse(c, "%s nests deeper than komira/python carries (the limit is %d)", c->path, UDFPY_MAX_DEPTH);
  if (out->n_nodes >= UDFPY_MAX_NODES)
    return refuse(c, "%s has more type nodes than komira/python carries (the limit is %d)", c->path,
                  UDFPY_MAX_NODES);
  if (s == NULL) return refuse(c, "type '%s' of %s is not built in komira/python yet", fmt, c->path);
  const char* name = s->name != NULL ? s->name : "";
  size_t name_n = strlen(name);
  if (name_n >= UDFPY_MAX_NAME)
    return refuse(c, "a name of %zu bytes in %s is not built in komira/python yet (the limit is %d)", name_n, c->path,
                  UDFPY_MAX_NAME - 1);
  if (s->dictionary != NULL) return refuse(c, "a dictionary-encoded %s is not built in komira/python yet", c->path);
  udfpy_type t;
  memset(&t, 0, sizeof(t));
  if (!parse_format(fmt, &t) ||
      (s->n_children != 0 && t.kind != UDFPY_K_LIST && t.kind != UDFPY_K_STRUCT))
    return refuse(c, "type '%s' of %s is not built in komira/python yet", fmt, c->path);
  if (t.kind == UDFPY_K_TIMESTAMP) {
    size_t tz_n = strlen(fmt + 4);
    if (tz_n >= UDFPY_MAX_NAME)
      return refuse(c, "a time zone of %zu bytes in %s is not built in komira/python yet (the limit is %d)", tz_n,
                    c->path, UDFPY_MAX_NAME - 1);
    memcpy(t.tz, fmt + 4, tz_n + 1);
  }
  if (t.kind == UDFPY_K_LIST && s->n_children != 1)
    return refuse(c, "type '%s' of %s has %lld children, not 1", fmt, c->path, (long long)s->n_children);
  if (t.kind == UDFPY_K_STRUCT && s->n_children < 1)
    return refuse(c, "type '%s' of %s has no children", fmt, c->path);
  t.nullable = (s->flags & ARROW_FLAG_NULLABLE) != 0;
  memcpy(t.name, name, name_n + 1);
  int me = out->n_nodes++;
  t.n_children = (int32_t)s->n_children;
  out->t[me] = t;
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema* child = s->children != NULL ? s->children[i] : NULL;
    const char* child_name = child != NULL && child->name != NULL ? child->name : "";
    /* Refused here, before the name joins the path: the message names the
     * node that holds it, and the path never holds a cut name. */
    if (strlen(child_name) >= UDFPY_MAX_NAME)
      return refuse(c, "a name of %zu bytes in %s is not built in komira/python yet (the limit is %d)",
                    strlen(child_name), c->path, UDFPY_MAX_NAME - 1);
    size_t save = c->plen;
    path_push(c, child_name);
    int rc = read_node(c, child, depth + 1);
    path_pop(c, save);
    if (rc != 0) return rc;
  }
  out->t[me].next = out->n_nodes;
  return 0;
}

int udfpy_schema_read(const struct ArrowSchema* s, int columns, udfpy_schema* out, char* why, size_t why_n) {
  memset(out, 0, sizeof(*out));
  ctx c;
  c.out = out;
  c.why = why;
  c.why_n = why_n;
  c.plen = 0;
  c.path[0] = 0;
  if (columns == 0) {
    path_set(&c, "the result");
    if (read_node(&c, s, 1) != 0) return -1;
    out->n = 1;
    return 0;
  }
  if (s == NULL || s->format == NULL || strcmp(s->format, "+s") != 0)
    return refuse(&c, "type '%s' of the arguments is not built in komira/python yet",
                  s != NULL && s->format != NULL ? s->format : "");
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema* child = s->children != NULL ? s->children[i] : NULL;
    path_set(&c, child != NULL && child->name != NULL ? child->name : "");
    if (read_node(&c, child, 1) != 0) return -1;
    out->n++;
  }
  return 0;
}
