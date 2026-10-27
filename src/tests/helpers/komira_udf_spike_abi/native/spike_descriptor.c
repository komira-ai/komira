/*
 * The decoder and validate's comparison of the spike descriptor, version 1
 * (komira_udf_spike_descriptor.h states the message and its canonical form).
 * Shared by every spike runtime written in C, so each refuses the same
 * bytes for the same reason. Pure: it reads the spec and the bytes it is
 * given, and nothing else (no code object, no file).
 */
#include <stdio.h>
#include <string.h>

#include "komira_udf_spike_descriptor.h"

/* ---- wire format ------------------------------------------------------------ */

typedef struct {
  const uint8_t* p;
  size_t n;
  size_t at;
  char* why;
  size_t why_len;
} rd;

static int bad(rd* r, const char* what) {
  snprintf(r->why, r->why_len, "the descriptor is not canonical: %s", what);
  return -1;
}

/* A varint in its shortest form, at most 32 bits wide. */
static int varint(rd* r, uint64_t* v) {
  uint64_t x = 0;
  for (int i = 0; i < 10; i++) {
    if (r->at >= r->n) return bad(r, "a varint runs past the end");
    uint8_t b = r->p[r->at++];
    x |= (uint64_t)(b & 0x7F) << (7 * i);
    if ((b & 0x80) == 0) {
      if (i > 0 && b == 0) return bad(r, "a varint is longer than its shortest form");
      if (x > 0xFFFFFFFFu) return bad(r, "a varint above 32 bits");
      *v = x;
      return 0;
    }
  }
  return bad(r, "a varint of more than ten bytes");
}

/* A length-delimited value: *p and *len, inside the bytes. */
static int bytes_of(rd* r, const uint8_t** p, size_t* len) {
  uint64_t l;
  if (varint(r, &l) != 0) return -1;
  if (l > r->n - r->at) return bad(r, "a length runs past the end");
  *p = r->p + r->at;
  *len = (size_t)l;
  r->at += (size_t)l;
  return 0;
}

/* The next tag: field number and wire type, held to the canonical order. A
 * field number below the last one, or the same non-repeated one twice, is
 * refused. */
static int tag(rd* r, uint32_t* last, uint32_t repeated_mask, uint32_t* field, uint32_t* wt) {
  uint64_t t;
  if (varint(r, &t) != 0) return -1;
  *field = (uint32_t)(t >> 3);
  *wt = (uint32_t)(t & 7);
  if (*field == 0) return bad(r, "field number 0");
  if (*field < *last) return bad(r, "fields out of ascending order");
  if (*field == *last && (*field >= 32 || ((repeated_mask >> *field) & 1) == 0)) {
    char m[64];
    snprintf(m, sizeof(m), "field %u appears twice", *field);
    return bad(r, m);
  }
  *last = *field;
  return 0;
}

static int want_wt(rd* r, uint32_t field, uint32_t wt, uint32_t want) {
  if (wt == want) return 0;
  char m[64];
  snprintf(m, sizeof(m), "field %u has wire type %u, not %u", field, wt, want);
  return bad(r, m);
}

static int unknown(rd* r, const char* msg, uint32_t field) {
  char m[96];
  snprintf(m, sizeof(m), "an unknown field %u in %s", field, msg);
  return bad(r, m);
}

/* message SpikeField { string name = 1; string format = 2; } */
static int field_msg(rd* outer, const uint8_t* p, size_t n, komira_udf_spike_field* f) {
  rd r = {p, n, 0, outer->why, outer->why_len};
  memset(f, 0, sizeof(*f));
  uint32_t last = 0;
  while (r.at < r.n) {
    uint32_t fn, wt;
    if (tag(&r, &last, 0, &fn, &wt) != 0) return -1;
    if (fn == 1 || fn == 2) {
      const uint8_t* s;
      size_t l;
      if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
      if (l == 0) return bad(&r, "an empty string is emitted");
      if (fn == 1) {
        f->name = s;
        f->name_len = l;
      } else {
        f->format = s;
        f->format_len = l;
      }
    } else {
      return unknown(&r, "a field", fn);
    }
  }
  if (f->format == NULL) return bad(&r, "a field without a format");
  return 0;
}

static int push(rd* r, komira_udf_spike_field* list, size_t* n, const uint8_t* p, size_t len) {
  if (*n >= KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS) return bad(r, "more fields than this decoder holds");
  return field_msg(r, p, len, &list[(*n)++]);
}

/* message RecordedFields { repeated SpikeField fields = 1; repeated SpikeField key_fields = 2; } */
static int recorded_msg(rd* outer, const uint8_t* p, size_t n, komira_udf_spike_descriptor* d) {
  rd r = {p, n, 0, outer->why, outer->why_len};
  uint32_t last = 0;
  while (r.at < r.n) {
    uint32_t fn, wt;
    if (tag(&r, &last, (1u << 1) | (1u << 2), &fn, &wt) != 0) return -1;
    const uint8_t* s;
    size_t l;
    if (fn != 1 && fn != 2) return unknown(&r, "recorded_fields", fn);
    if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
    if (push(&r, fn == 1 ? d->fields : d->keys, fn == 1 ? &d->n_fields : &d->n_keys, s, l) != 0) return -1;
  }
  return 0;
}

int komira_udf_spike_descriptor_decode(const uint8_t* bytes, size_t n, komira_udf_spike_descriptor* d, char* why,
                                       size_t why_len) {
  rd r = {bytes, n, 0, why, why_len};
  memset(d, 0, sizeof(*d));
  uint32_t last = 0;
  while (r.at < r.n) {
    uint32_t fn, wt;
    if (tag(&r, &last, (1u << 3) | (1u << 4), &fn, &wt) != 0) return -1;
    const uint8_t* s;
    size_t l;
    uint64_t v;
    switch (fn) {
      case 1:
        if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
        if (l == 0) return bad(&r, "an empty entry is emitted");
        d->entry = s;
        d->entry_len = l;
        break;
      case 2:
        if (want_wt(&r, fn, wt, 0) != 0 || varint(&r, &v) != 0) return -1;
        if (v == 0) return bad(&r, "shapes 0 is emitted");
        d->shapes = (uint32_t)v;
        break;
      case 3:
      case 4:
        if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
        if (push(&r, fn == 3 ? d->args : d->result, fn == 3 ? &d->n_args : &d->n_result, s, l) != 0) return -1;
        break;
      case 5:
        if (want_wt(&r, fn, wt, 0) != 0 || varint(&r, &v) != 0) return -1;
        if (v != 1) return bad(&r, "result_is_table is emitted as other than true");
        d->result_is_table = 1;
        break;
      case 6:
        if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
        if (field_msg(&r, s, l, &d->state) != 0) return -1;
        d->has_state = 1;
        break;
      case 7:
        if (want_wt(&r, fn, wt, 2) != 0 || bytes_of(&r, &s, &l) != 0) return -1;
        if (recorded_msg(&r, s, l, d) != 0) return -1;
        d->has_recorded = 1;
        break;
      default:
        return unknown(&r, "the descriptor", fn);
    }
  }
  return 0;
}

/* ---- the comparison ------------------------------------------------------------- */

const char* komira_udf_spike_type_name(const char* format, size_t len, char* buf, size_t buf_len) {
  if (len == 1 && format[0] == 'l') return "int64";
  if (len == 1 && format[0] == 'g') return "float64";
  if (len == 1 && format[0] == 'i') return "int32";
  if (len == 2 && format[0] == '+' && format[1] == 's') return "struct";
  snprintf(buf, buf_len, "'%.*s'", (int)(len < 32 ? len : 32), format);
  return buf;
}

static int same(const uint8_t* a, size_t al, const char* b) {
  size_t bl = b != NULL ? strlen(b) : 0;
  return al == bl && (al == 0 || memcmp(a, b, al) == 0);
}

/* UTF-8 byte order of two names. */
static int name_cmp(const uint8_t* a, size_t al, const uint8_t* b, size_t bl) {
  int c = memcmp(a, b, al < bl ? al : bl);
  if (c != 0) return c;
  return al < bl ? -1 : al > bl ? 1 : 0;
}

/* The spec's type of `s` against a recorded field: `where` names it. */
static int32_t type_differs(const struct ArrowSchema* s, const komira_udf_spike_field* f, const char* where,
                            char* why, size_t why_len) {
  const char* fmt = s != NULL && s->format != NULL ? s->format : "";
  if (same(f->format, f->format_len, fmt)) return KOMIRA_UDF_OK;
  char a[48], b[48];
  snprintf(why, why_len, "%s: the spec says %s, the descriptor %s", where,
           komira_udf_spike_type_name(fmt, strlen(fmt), a, sizeof(a)),
           komira_udf_spike_type_name((const char*)f->format, f->format_len, b, sizeof(b)));
  return KOMIRA_UDF_ERR_DESCRIPTOR;
}

static const char* shape_name(uint32_t bit) {
  switch (bit) {
    case KOMIRA_UDF_SHAPE_SCALAR: return "SCALAR";
    case KOMIRA_UDF_SHAPE_ROW: return "ROW";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN: return "MAP_BATCHES_COLUMN";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME: return "MAP_BATCHES_FRAME";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED: return "MAP_BATCHES_FRAME_GROUPED";
    case KOMIRA_UDF_SHAPE_AGG_PLAIN: return "AGG_PLAIN";
    case KOMIRA_UDF_SHAPE_AGG_MERGEABLE: return "AGG_MERGEABLE";
    case KOMIRA_UDF_SHAPE_STEP: return "STEP";
    default: return "an unknown shape";
  }
}

/* One list's canonical order: strictly ascending names (equal names are a
 * repeated name). */
static int32_t list_order(const komira_udf_spike_field* l, size_t n, const char* list, char* why, size_t why_len) {
  for (size_t i = 0; i < n; i++) {
    if (l[i].name == NULL) {
      snprintf(why, why_len, "recorded_fields.%s[%zu] has no name", list, i);
      return KOMIRA_UDF_ERR_DESCRIPTOR;
    }
    if (i == 0) continue;
    int c = name_cmp(l[i - 1].name, l[i - 1].name_len, l[i].name, l[i].name_len);
    if (c == 0) {
      snprintf(why, why_len, "recorded_fields.%s repeats the name '%.*s'", list, (int)l[i].name_len,
               (const char*)l[i].name);
      return KOMIRA_UDF_ERR_DESCRIPTOR;
    }
    if (c > 0) {
      snprintf(why, why_len, "recorded_fields.%s is not sorted by name: '%.*s' before '%.*s'", list,
               (int)l[i - 1].name_len, (const char*)l[i - 1].name, (int)l[i].name_len, (const char*)l[i].name);
      return KOMIRA_UDF_ERR_DESCRIPTOR;
    }
  }
  return KOMIRA_UDF_OK;
}

/* "{a, b}" of `n` names into buf. */
static void name_list(char* buf, size_t len, const char* const* names, size_t n) {
  size_t at = (size_t)snprintf(buf, len, "{");
  for (size_t i = 0; i < n && at < len; i++)
    at += (size_t)snprintf(buf + at, len - at, "%s%s", i ? ", " : "", names[i]);
  if (at < len) snprintf(buf + at, len - at, "}");
}

static void field_list(char* buf, size_t len, const komira_udf_spike_field* const* fs, size_t n) {
  size_t at = (size_t)snprintf(buf, len, "{");
  for (size_t i = 0; i < n && at < len; i++)
    at += (size_t)snprintf(buf + at, len - at, "%s%.*s", i ? ", " : "", (int)fs[i]->name_len, (const char*)fs[i]->name);
  if (at < len) snprintf(buf + at, len - at, "}");
}

/* ROW and MAP_BATCHES_FRAME: the arg_types names against the recorded
 * fields, as sorted sets; then, with equal names, the types. */
static int32_t read_set(const komira_udf_spec* s, const komira_udf_spike_descriptor* d, char* why, size_t why_len) {
  int32_t rc = list_order(d->fields, d->n_fields, "fields", why, why_len);
  if (rc == KOMIRA_UDF_OK) rc = list_order(d->keys, d->n_keys, "key_fields", why, why_len);
  if (rc != KOMIRA_UDF_OK) return rc;
  for (size_t k = 0; k < d->n_keys; k++)
    for (size_t i = 0; i < d->n_fields; i++)
      if (name_cmp(d->keys[k].name, d->keys[k].name_len, d->fields[i].name, d->fields[i].name_len) == 0) {
        snprintf(why, why_len, "recorded_fields: the key '%.*s' is also in fields", (int)d->keys[k].name_len,
                 (const char*)d->keys[k].name);
        return KOMIRA_UDF_ERR_DESCRIPTOR;
      }
  /* The union of both lists, sorted by name (a merge of two sorted lists). */
  const komira_udf_spike_field* u[2 * KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  size_t nu = 0, i = 0, k = 0;
  while (i < d->n_fields || k < d->n_keys) {
    int take_field = k >= d->n_keys ||
                     (i < d->n_fields &&
                      name_cmp(d->fields[i].name, d->fields[i].name_len, d->keys[k].name, d->keys[k].name_len) < 0);
    u[nu++] = take_field ? &d->fields[i++] : &d->keys[k++];
  }
  /* The spec's argument names, sorted. */
  int64_t na = s->args != NULL ? s->args->n_children : 0;
  if (na < 0 || na > KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS) {
    snprintf(why, why_len, "the spec has %lld arguments", (long long)na);
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  const char* names[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  const struct ArrowSchema* kids[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  for (int64_t a = 0; a < na; a++) {
    const struct ArrowSchema* c = s->args->children[a];
    const char* nm = c != NULL && c->name != NULL ? c->name : "";
    int64_t at = a;
    while (at > 0 && strcmp(names[at - 1], nm) > 0) {
      names[at] = names[at - 1];
      kids[at] = kids[at - 1];
      at--;
    }
    names[at] = nm;
    kids[at] = c;
  }
  int differ = (size_t)na != nu;
  for (size_t j = 0; !differ && j < nu; j++) differ = !same(u[j]->name, u[j]->name_len, names[j]);
  if (differ) {
    char a[400], b[400];
    field_list(a, sizeof(a), u, nu);
    name_list(b, sizeof(b), names, (size_t)na);
    snprintf(why, why_len, "the descriptor records the fields %s, the spec's arg_types are named %s", a, b);
    return KOMIRA_UDF_ERR_READ_SET_MISMATCH;
  }
  for (size_t j = 0; j < nu; j++) {
    char where[160];
    snprintf(where, sizeof(where), "arg_types field '%s'", names[j]);
    rc = type_differs(kids[j], u[j], where, why, why_len);
    if (rc != KOMIRA_UDF_OK) return rc;
  }
  return KOMIRA_UDF_OK;
}

int32_t komira_udf_spike_descriptor_check(const komira_udf_spec* s, int absent_fields_refused,
                                          komira_udf_spike_descriptor* d, char* why, size_t why_len) {
  if (s->descriptor_version == 0) {
    snprintf(why, why_len,
             "descriptor_version 0 carries no descriptor, and validate compares the signature the descriptor records");
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  if (s->descriptor_version > KOMIRA_UDF_SPIKE_DESCRIPTOR_VERSION) {
    snprintf(why, why_len, "descriptor_version %u is newer than %u, the newest read here", s->descriptor_version,
             KOMIRA_UDF_SPIKE_DESCRIPTOR_VERSION);
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  if (s->descriptor_len > 0 && s->descriptor == NULL) {
    snprintf(why, why_len, "descriptor bytes are NULL");
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  if (komira_udf_spike_descriptor_decode(s->descriptor, s->descriptor_len, d, why, why_len) != 0)
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  if (!same(d->entry, d->entry_len, s->entry)) {
    snprintf(why, why_len, "the descriptor's entry '%.*s' is not the spec's entry '%s'", (int)d->entry_len,
             d->entry != NULL ? (const char*)d->entry : "", s->entry != NULL ? s->entry : "");
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  uint32_t shape = (uint32_t)s->shape;
  if ((d->shapes & shape) == 0 || (shape & (shape - 1)) != 0) {
    snprintf(why, why_len, "the descriptor does not list the shape %s for this entry", shape_name(shape));
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  int32_t rc = KOMIRA_UDF_OK;
  uint32_t by_name =
      KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED;
  if (shape & by_name) {
    if (d->has_recorded)
      rc = read_set(s, d, why, why_len);
    else if (absent_fields_refused) {
      snprintf(why, why_len, "the descriptor records no field list, which this runtime needs for %s",
               shape_name(shape));
      rc = KOMIRA_UDF_ERR_DESCRIPTOR;
    }
  } else {
    int64_t na = s->args != NULL ? s->args->n_children : 0;
    if ((size_t)na != d->n_args) {
      snprintf(why, why_len, "arg_types: the spec has %lld, the descriptor %zu", (long long)na, d->n_args);
      rc = KOMIRA_UDF_ERR_DESCRIPTOR;
    }
    for (int64_t a = 0; rc == KOMIRA_UDF_OK && a < na; a++) {
      char where[48];
      snprintf(where, sizeof(where), "arg_types[%lld]", (long long)a);
      rc = type_differs(s->args->children[a], &d->args[a], where, why, why_len);
    }
  }
  if (rc != KOMIRA_UDF_OK) return rc;
  const struct ArrowSchema* res = s->result;
  int table = res != NULL && res->format != NULL && strcmp(res->format, "+s") == 0;
  if (table != d->result_is_table) {
    snprintf(why, why_len, "return_type: the spec says %s, the descriptor %s", table ? "a table" : "a column",
             d->result_is_table ? "a table" : "a column");
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  size_t nr = table ? (size_t)res->n_children : (res != NULL ? 1 : 0);
  if (nr != d->n_result) {
    snprintf(why, why_len, "return_type: the spec has %zu fields, the descriptor %zu", nr, d->n_result);
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  for (size_t i = 0; i < nr; i++) {
    char where[48];
    if (table)
      snprintf(where, sizeof(where), "return_type[%zu]", i);
    else
      snprintf(where, sizeof(where), "return_type");
    rc = type_differs(table ? res->children[i] : res, &d->result[i], where, why, why_len);
    if (rc != KOMIRA_UDF_OK) return rc;
  }
  if ((s->state != NULL) != d->has_state) {
    snprintf(why, why_len, "state_type: the spec has %s, the descriptor %s", s->state != NULL ? "one" : "none",
             d->has_state ? "one" : "none");
    return KOMIRA_UDF_ERR_DESCRIPTOR;
  }
  if (s->state != NULL) return type_differs(s->state, &d->state, "state_type", why, why_len);
  return KOMIRA_UDF_OK;
}
