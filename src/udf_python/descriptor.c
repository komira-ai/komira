/*
 * descriptor.c: validate, the pure check of a spec against its descriptor.
 *
 * The descriptor is a protobuf message, decoded here by hand: no library,
 * no allocation, no file opened, no process started. It must be canonical
 * (fields in ascending number, each at most once, the right wire type,
 * varints in their shortest form, no field equal to its default), so one
 * set of values has one set of bytes.
 *
 * Version 1 fields read by this build: 1 entry, 2 shapes, 7 batch_format,
 * 10 is_async. Fields 3, 4, 5, 6, 8, 9 and 11 are fields of the descriptor
 * that this build does not read; they are refused by number. Any other
 * field number is not a field of the message.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "udfpy.h"

#define FORM_PACKAGE 1
#define FORM_BUNDLE 2
#define FORM_VALUE 3

enum { BF_VALUES = 1, BF_ARROW = 2, BF_PANDAS = 3, BF_NUMPY = 4, BF_POLARS = 5 };

#define KNOWN_SHAPES                                                                                      \
  (KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN |                   \
   KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED |                         \
   KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_AGG_MERGEABLE | KOMIRA_UDF_SHAPE_STEP)

typedef struct desc {
  const uint8_t* entry;
  size_t entry_len;
  uint32_t shapes;
  uint32_t batch_format;
  int is_async;
  int unsupported; /* the first field this build does not read, or 0 */
} desc;

static const char* shape_name(uint32_t shape) {
  switch (shape) {
    case KOMIRA_UDF_SHAPE_SCALAR: return "SCALAR";
    case KOMIRA_UDF_SHAPE_ROW: return "ROW";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN: return "MAP_BATCHES_COLUMN";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME: return "MAP_BATCHES_FRAME";
    case KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED: return "MAP_BATCHES_FRAME_GROUPED";
    case KOMIRA_UDF_SHAPE_AGG_PLAIN: return "AGG_PLAIN";
    case KOMIRA_UDF_SHAPE_AGG_MERGEABLE: return "AGG_MERGEABLE";
    case KOMIRA_UDF_SHAPE_STEP: return "STEP";
    default: return NULL;
  }
}

static const char* format_name(uint32_t f) {
  switch (f) {
    case BF_VALUES: return "VALUES";
    case BF_ARROW: return "ARROW";
    case BF_PANDAS: return "PANDAS";
    case BF_NUMPY: return "NUMPY";
    case BF_POLARS: return "POLARS";
    default: return NULL;
  }
}

static const char* unread_name(int field) {
  switch (field) {
    case 3: return "arg_types";
    case 4: return "return_type";
    case 5: return "state_type";
    case 6: return "recorded_fields";
    case 8: return "serializer";
    case 9: return "python_abi";
    case 11: return "distribution";
    default: return "?";
  }
}

/* ---- the protobuf reader ------------------------------------------------------ */

typedef struct rd {
  const uint8_t* p;
  size_t n, at;
  char why[160];
} rd;

static int bad(rd* r, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static int bad(rd* r, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(r->why, sizeof(r->why), fmt, ap);
  va_end(ap);
  return -1;
}

/* A varint of at most 64 bits in its shortest form. */
static int varint(rd* r, uint64_t* out) {
  uint64_t v = 0;
  size_t start = r->at;
  for (int i = 0; i < 10; i++) {
    if (r->at >= r->n) return bad(r, "truncated at byte %zu", r->at);
    uint8_t b = r->p[r->at++];
    if (i == 9 && b > 1) return bad(r, "varint above 64 bits at byte %zu", start);
    v |= (uint64_t)(b & 0x7f) << (7 * i);
    if ((b & 0x80) == 0) {
      if (i > 0 && b == 0) return bad(r, "varint not in shortest form at byte %zu", start);
      *out = v;
      return 0;
    }
  }
  return bad(r, "varint not in shortest form at byte %zu", start);
}

static int skip_value(rd* r, unsigned wt) {
  uint64_t v;
  switch (wt) {
    case 0:
      return varint(r, &v);
    case 1:
      if (r->n - r->at < 8) return bad(r, "truncated at byte %zu", r->at);
      r->at += 8;
      return 0;
    case 2:
      if (varint(r, &v) != 0) return -1;
      if (v > r->n - r->at) return bad(r, "truncated at byte %zu", r->at);
      r->at += (size_t)v;
      return 0;
    case 5:
      if (r->n - r->at < 4) return bad(r, "truncated at byte %zu", r->at);
      r->at += 4;
      return 0;
    default:
      return bad(r, "wire type %u is not a wire type this decoder reads", wt);
  }
}

/* A uint32 or bool field: wire type 0, shortest, not its default, in range. */
static int scalar(rd* r, int field, unsigned wt, uint64_t max, uint32_t* out) {
  uint64_t v = 0;
  if (wt != 0) return bad(r, "field %d has wire type %u", field, wt);
  if (varint(r, &v) != 0) return -1;
  if (v == 0) return bad(r, "field %d holds its default", field);
  if (v > max) return bad(r, "field %d is above %llu", field, (unsigned long long)max);
  *out = (uint32_t)v;
  return 0;
}

static int decode(const uint8_t* bytes, size_t n, desc* d, char* why, size_t why_len) {
  rd r = {bytes, n, 0, {0}};
  memset(d, 0, sizeof(*d));
  uint64_t last = 0;
  int have_entry = 0, have_shapes = 0, have_format = 0;
  int rc = 0;
  while (r.at < r.n && rc == 0) {
    uint64_t tag;
    if (varint(&r, &tag) != 0) {
      rc = -1;
      break;
    }
    uint64_t field = tag >> 3;
    unsigned wt = (unsigned)(tag & 7);
    if (field == 0 || field > 0x1fffffff) {
      rc = bad(&r, "field %llu is not a PythonDescriptor field", (unsigned long long)field);
      break;
    }
    if (field < last) {
      rc = bad(&r, "fields out of order at field %llu", (unsigned long long)field);
      break;
    }
    if (field == last) {
      rc = bad(&r, "field %llu repeated", (unsigned long long)field);
      break;
    }
    last = field;
    switch (field) {
      case 1: {
        uint64_t len = 0;
        if (wt != 2) {
          rc = bad(&r, "field 1 has wire type %u", wt);
          break;
        }
        if (varint(&r, &len) != 0) {
          rc = -1;
          break;
        }
        if (len > r.n - r.at) {
          rc = bad(&r, "truncated at byte %zu", r.at);
          break;
        }
        if (len == 0) {
          rc = bad(&r, "field 1 holds its default");
          break;
        }
        d->entry = r.p + r.at;
        d->entry_len = (size_t)len;
        r.at += (size_t)len;
        have_entry = 1;
        break;
      }
      case 2:
        rc = scalar(&r, 2, wt, 0xffffffffu, &d->shapes);
        have_shapes = rc == 0;
        break;
      case 7:
        rc = scalar(&r, 7, wt, 0xffffffffu, &d->batch_format);
        have_format = rc == 0;
        break;
      case 10: {
        uint32_t v = 0;
        rc = scalar(&r, 10, wt, 1, &v);
        d->is_async = (int)v;
        break;
      }
      case 3:
      case 4:
      case 5:
      case 6:
      case 8:
      case 9:
      case 11:
        rc = skip_value(&r, wt);
        if (rc == 0 && d->unsupported == 0) d->unsupported = (int)field;
        break;
      default:
        rc = bad(&r, "descriptor field %llu is not a PythonDescriptor field", (unsigned long long)field);
        break;
    }
  }
  if (rc == 0 && !have_entry) rc = bad(&r, "descriptor field 1 (entry) is missing");
  if (rc == 0 && !have_shapes) rc = bad(&r, "descriptor field 2 (shapes) is missing");
  if (rc == 0 && !have_format) rc = bad(&r, "descriptor field 7 (batch_format) is missing");
  if (rc != 0) snprintf(why, why_len, "%s", r.why);
  return rc;
}

/* ---- the entry grammar --------------------------------------------------------- */

static int ident_char(int c, int first) {
  if (c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return 1;
  return !first && c >= '0' && c <= '9';
}

/* dotted identifiers: ident ("." ident)*, from s to the end */
static int dotted(const char* s, size_t n) {
  if (n == 0) return 0;
  int first = 1;
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '.') {
      if (first) return 0; /* empty part */
      first = 1;
      continue;
    }
    if (!ident_char((unsigned char)s[i], first)) return 0;
    first = 0;
  }
  return !first;
}

static int entry_ok(const char* e) {
  const char* colon = strchr(e, ':');
  if (colon == NULL) return 0;
  return dotted(e, (size_t)(colon - e)) && dotted(colon + 1, strlen(colon + 1));
}

/* ---- types ---------------------------------------------------------------------- */

static int carried(const struct ArrowSchema* s) {
  return s != NULL && s->format != NULL && s->format[0] != 0 && s->format[1] == 0 &&
         (s->format[0] == 'l' || s->format[0] == 'i' || s->format[0] == 'g') && s->n_children == 0;
}

static int32_t check_types(const komira_udf_spec* s, komira_udf_error* err) {
  if (s->args == NULL || s->args->format == NULL || strcmp(s->args->format, "+s") != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "type '%s' of the arguments is not built in komira/python yet",
                      s->args != NULL && s->args->format != NULL ? s->args->format : "");
  if (s->args->n_children > UDFPY_MAX_FIELDS)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1,
                      "%lld arguments are not built in komira/python yet (the limit is %d)",
                      (long long)s->args->n_children, UDFPY_MAX_FIELDS);
  for (int64_t i = 0; i < s->args->n_children; i++) {
    const struct ArrowSchema* c = s->args->children[i];
    const char* name = c != NULL && c->name != NULL ? c->name : "";
    if (strlen(name) >= UDFPY_MAX_NAME)
      return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1,
                        "an argument name of %zu bytes is not built in komira/python yet (the limit is %d)",
                        strlen(name), UDFPY_MAX_NAME - 1);
    if (!carried(c))
      return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "type '%s' of %s is not built in komira/python yet",
                        c != NULL && c->format != NULL ? c->format : "", name);
  }
  if (!carried(s->result))
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1,
                      "type '%s' of the result is not built in komira/python yet",
                      s->result != NULL && s->result->format != NULL ? s->result->format : "");
  return KOMIRA_UDF_OK;
}

/* ---- validate ------------------------------------------------------------------- */

int32_t udfpy_validate(const komira_udf_spec* s, uint32_t* batch_format, komira_udf_error* err) {
  if (s == NULL || s->struct_size < sizeof(*s))
    return udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "komira/python needs a komira_udf_spec of ABI 1.0");
  if (s->descriptor_version != 1)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "descriptor_version %u: this runtime reads version 1",
                      s->descriptor_version);
  if (s->descriptor == NULL && s->descriptor_len > 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "a descriptor of %zu bytes with no bytes", s->descriptor_len);
  desc d;
  char why[200];
  if (decode(s->descriptor, s->descriptor_len, &d, why, sizeof(why)) != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "%s", why);
  if (d.unsupported != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1,
                      "descriptor field %d (%s) is not read by this build of komira/python", d.unsupported,
                      unread_name(d.unsupported));
  const char* entry = s->entry != NULL ? s->entry : "";
  if (d.entry_len != strlen(entry) || memcmp(d.entry, entry, d.entry_len) != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "descriptor entry '%.*s' differs from the UDF's entry '%s'",
                      (int)d.entry_len, (const char*)d.entry, entry);
  if (!entry_ok(entry)) return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "entry '%s' is not module:qualname", entry);
  if ((d.shapes & ~(uint32_t)KNOWN_SHAPES) != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "the descriptor's shapes 0x%x name a shape this runtime does not know",
                      d.shapes);
  uint32_t shape = (uint32_t)s->shape;
  const char* sname = shape_name(shape);
  if (sname == NULL)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "the UDF's shape %d is not one shape", (int)s->shape);
  if ((d.shapes & shape) == 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "the UDF's shape %s is not in the descriptor's shapes", sname);
  const char* fname = format_name(d.batch_format);
  if (fname == NULL)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "batch format %u is not a batch format", d.batch_format);
  if (shape != KOMIRA_UDF_SHAPE_SCALAR && shape != KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "shape %s is not built in komira/python yet", sname);
  if (d.batch_format == BF_PANDAS || d.batch_format == BF_NUMPY || d.batch_format == BF_POLARS)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "batch format %s is not built in komira/python yet", fname);
  if (shape == KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN && d.batch_format == BF_VALUES)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "batch format VALUES does not apply to MAP_BATCHES_COLUMN");
  if (d.is_async)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "async functions are not built in komira/python yet");
  if (s->form == FORM_VALUE)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "code form VALUE is not built in komira/python yet");
  if (s->form != FORM_PACKAGE && s->form != FORM_BUNDLE)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "code form %d is not PACKAGE, BUNDLE or VALUE", (int)s->form);
  int32_t rc = check_types(s, err);
  if (rc != KOMIRA_UDF_OK) return rc;
  if (s->form == FORM_BUNDLE &&
      (s->n_code != 1 || s->code_roles == NULL || s->code_roles[0] == NULL || strcmp(s->code_roles[0], "bundle") != 0))
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "a BUNDLE lists exactly one code object of role 'bundle'");
  if (s->n_code != 0 && s->code_sha256 == NULL)
    return udfpy_fail(err, KOMIRA_UDF_ERR_HOST_CONTRACT, -1, "spec lists %zu code objects and no code_sha256", s->n_code);
  if (s->form == FORM_PACKAGE && s->n_code != 0)
    return udfpy_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "a PACKAGE lists no code object");
  if (batch_format != NULL) *batch_format = d.batch_format;
  return KOMIRA_UDF_OK;
}
