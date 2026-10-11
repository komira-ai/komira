/*
 * The JSON object the probes return: one member per case,
 * {"status": n, "message": "...", "value": n}. Test-only spike code.
 */
#ifndef KOMIRA_UDF_PYW_PROBE_JSON_H
#define KOMIRA_UDF_PYW_PROBE_JSON_H

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

struct pj {
  char* p;
  size_t len, cap;
  int n;
};

static void pj_add(struct pj* j, const char* fmt, ...) {
  va_list ap;
  for (;;) {
    size_t room = j->cap - j->len;
    va_start(ap, fmt);
    int n = vsnprintf(j->p ? j->p + j->len : NULL, j->p ? room : 0, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (j->p && (size_t)n < room) {
      j->len += (size_t)n;
      return;
    }
    size_t c = j->cap ? j->cap * 2 : 4096;
    while (c < j->len + (size_t)n + 1) c *= 2;
    char* q = realloc(j->p, c);
    if (q == NULL) return;
    j->p = q;
    j->cap = c;
  }
}

static void pj_open(struct pj* j) { pj_add(j, "{"); }

static void pj_case(struct pj* j, const char* name, int64_t status, const char* message, int64_t value) {
  pj_add(j, "%s\"%s\": {\"status\": %lld, \"message\": \"", j->n++ ? ", " : "", name, (long long)status);
  for (const char* s = message; s && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') pj_add(j, "\\%c", c);
    else if (c < 0x20) pj_add(j, " ");
    else pj_add(j, "%c", c);
  }
  pj_add(j, "\", \"value\": %lld}", (long long)value);
}

static char* pj_close(struct pj* j) {
  pj_add(j, "}");
  return j->p;
}

#endif /* KOMIRA_UDF_PYW_PROBE_JSON_H */
