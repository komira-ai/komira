/*
 * A consumer of the Arrow C Stream Interface, written in C against the
 * structs of the Arrow specification (CStreamInterface.html,
 * CDataInterface.html) and nothing of komira's. It drives a stream as a
 * foreign host would, through the stream's own function pointers, and renders
 * what it read as text for the Mojo test to compare.
 *
 * komira_test_arrow_c_consume(stream, mode, out, cap, out_len) -> int32
 *
 *   mode 0, drain: get_schema; get_next until the end of the stream; release
 *     the schema and then the stream; read every chunk after the stream is
 *     gone; release each chunk.
 *   mode 1, unread: release the stream without calling anything else.
 *   mode 2, first chunk: get_schema; one get_next; release the schema and the
 *     stream; read that chunk; release it.
 *
 * Every release is checked: the callback must set the struct's `release` to
 * NULL, and calling the same callback again on the released struct must leave
 * it released (a second release is a no-op). The text, `*out_len` bytes and no
 * NUL, is one line per field (`field <name> <format> nullable|required`), then
 * per chunk `chunk <k> rows <n>` and one line per column: `<name>: v, v, ...`
 * with `null` for a NULL. Integers in decimal; a float64 with %.17g; a bool as
 * true/false; a string in double quotes, bytes as they are; a decimal128 as
 * its exact digits with the scale's decimal point; a date32 as its day count;
 * a dictionary row as its decoded string value.
 *
 * Returns 0, or 1 after writing the reason as the text: a callback that
 * failed (with its get_last_error), a release that did not take, a struct
 * that breaks the specification, a format this consumer does not read, or a
 * buffer `cap` too small for the text. A failure still releases every chunk
 * and the schema the consumer holds, and the stream, except after a failed
 * get_next, where the stream is left live for the caller to release.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct ArrowSchema {
  const char *format;
  const char *name;
  const char *metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema **children;
  struct ArrowSchema *dictionary;
  void (*release)(struct ArrowSchema *);
  void *private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void **buffers;
  struct ArrowArray **children;
  struct ArrowArray *dictionary;
  void (*release)(struct ArrowArray *);
  void *private_data;
};

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *);
  int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *);
  const char *(*get_last_error)(struct ArrowArrayStream *);
  void (*release)(struct ArrowArrayStream *);
  void *private_data;
};

#define ARROW_FLAG_NULLABLE 2
#define MAX_CHUNKS 64

typedef struct {
  char *buf;
  int64_t cap;
  int64_t len;
  int overflow;
} text;

static void put(text *t, const char *s, int64_t n) {
  if (t->len + n > t->cap) {
    t->overflow = 1;
    t->len += n;
    return;
  }
  memcpy(t->buf + t->len, s, (size_t)n);
  t->len += n;
}

static void puts_(text *t, const char *s) { put(t, s, (int64_t)strlen(s)); }

static void putf(text *t, const char *fmt, long long v) {
  char tmp[64];
  int n = snprintf(tmp, sizeof tmp, fmt, v);
  put(t, tmp, n);
}

/* A failure replaces the text with the reason. */
static int fail(text *t, const char *what, const char *detail) {
  t->len = 0;
  t->overflow = 0;
  puts_(t, what);
  if (detail != NULL) {
    puts_(t, ": ");
    puts_(t, detail);
  }
  return 1;
}

static int release_schema(text *t, struct ArrowSchema *s) {
  void (*rel)(struct ArrowSchema *) = s->release;
  rel(s);
  if (s->release != NULL) return fail(t, "the schema's release left release set", NULL);
  rel(s);
  if (s->release != NULL) return fail(t, "a second schema release set release again", NULL);
  return 0;
}

static int release_array(text *t, struct ArrowArray *a) {
  void (*rel)(struct ArrowArray *) = a->release;
  rel(a);
  if (a->release != NULL) return fail(t, "the chunk's release left release set", NULL);
  rel(a);
  if (a->release != NULL) return fail(t, "a second chunk release set release again", NULL);
  return 0;
}

static int release_stream(text *t, struct ArrowArrayStream *s) {
  void (*rel)(struct ArrowArrayStream *) = s->release;
  rel(s);
  if (s->release != NULL) return fail(t, "the stream's release left release set", NULL);
  rel(s);
  if (s->release != NULL) return fail(t, "a second stream release set release again", NULL);
  return 0;
}

static int is_null(const struct ArrowArray *a, int64_t i) {
  const uint8_t *validity = (const uint8_t *)a->buffers[0];
  if (validity == NULL) return 0;
  int64_t bit = a->offset + i;
  return ((validity[bit >> 3] >> (bit & 7)) & 1) == 0;
}

static int64_t index_at(const char *format, const void *data, int64_t j) {
  switch (format[0]) {
    case 'c': return ((const int8_t *)data)[j];
    case 'C': return ((const uint8_t *)data)[j];
    case 's': return ((const int16_t *)data)[j];
    case 'S': return ((const uint16_t *)data)[j];
    case 'i': return ((const int32_t *)data)[j];
    case 'I': return ((const uint32_t *)data)[j];
    default: return ((const int64_t *)data)[j];
  }
}

static void put_string(text *t, const struct ArrowArray *a, int64_t j, int large) {
  int64_t lo, hi;
  if (large) {
    lo = ((const int64_t *)a->buffers[1])[j];
    hi = ((const int64_t *)a->buffers[1])[j + 1];
  } else {
    lo = ((const int32_t *)a->buffers[1])[j];
    hi = ((const int32_t *)a->buffers[1])[j + 1];
  }
  puts_(t, "\"");
  put(t, (const char *)a->buffers[2] + lo, hi - lo);
  puts_(t, "\"");
}

/* The exact digits of a 128-bit two's complement value, with `scale` digits
 * after the point. */
static void put_decimal128(text *t, const uint8_t *bytes, int scale) {
  unsigned __int128 u;
  memcpy(&u, bytes, 16);
  int negative = (int)(u >> 127);
  if (negative) u = ~u + 1;
  char digits[48];
  int n = 0;
  do {
    digits[n++] = (char)('0' + (int)(u % 10));
    u /= 10;
  } while (u != 0);
  while (n <= scale) digits[n++] = '0';
  if (negative) puts_(t, "-");
  for (int k = n - 1; k >= 0; k--) {
    put(t, &digits[k], 1);
    if (k == scale && scale > 0) puts_(t, ".");
  }
}

static int decimal_scale(const char *format, int *scale) {
  int precision = 0, s = 0, width = 128;
  int got = sscanf(format, "d:%d,%d,%d", &precision, &s, &width);
  if (got < 2 || width != 128 || precision < 1 || s < 0) return 1;
  *scale = s;
  return 0;
}

static int put_value(text *t, const struct ArrowSchema *f, const struct ArrowArray *a, int64_t i) {
  if (is_null(a, i)) {
    puts_(t, "null");
    return 0;
  }
  int64_t j = a->offset + i;
  const char *format = f->format;
  if (f->dictionary != NULL) {
    if (strcmp(f->dictionary->format, "u") != 0 || a->dictionary == NULL)
      return fail(t, "a dictionary whose values are not utf8", f->dictionary->format);
    put_string(t, a->dictionary, a->dictionary->offset + index_at(format, a->buffers[1], j), 0);
    return 0;
  }
  if (strlen(format) == 1) {
    switch (format[0]) {
      case 'c': case 'C': case 's': case 'S': case 'i': case 'I': case 'l':
        putf(t, "%lld", (long long)index_at(format, a->buffers[1], j));
        return 0;
      case 'L': {
        char tmp[32];
        int n = snprintf(tmp, sizeof tmp, "%llu",
                         (unsigned long long)((const uint64_t *)a->buffers[1])[j]);
        put(t, tmp, n);
        return 0;
      }
      case 'g': {
        char tmp[40];
        int n = snprintf(tmp, sizeof tmp, "%.17g", ((const double *)a->buffers[1])[j]);
        put(t, tmp, n);
        return 0;
      }
      case 'b': {
        const uint8_t *bits = (const uint8_t *)a->buffers[1];
        puts_(t, ((bits[j >> 3] >> (j & 7)) & 1) ? "true" : "false");
        return 0;
      }
      case 'u': put_string(t, a, j, 0); return 0;
      case 'U': put_string(t, a, j, 1); return 0;
      default: break;
    }
  }
  if (strcmp(format, "tdD") == 0) {
    putf(t, "%lld", (long long)((const int32_t *)a->buffers[1])[j]);
    return 0;
  }
  int scale;
  if (format[0] == 'd' && decimal_scale(format, &scale) == 0) {
    put_decimal128(t, (const uint8_t *)a->buffers[1] + 16 * j, scale);
    return 0;
  }
  return fail(t, "a format this consumer does not read", format);
}

static int put_chunk(text *t, const struct ArrowSchema *schema, const struct ArrowArray *chunk, int k) {
  if (chunk->n_children != schema->n_children)
    return fail(t, "a chunk whose column count is not the schema's", NULL);
  if (chunk->length < 0 || chunk->offset != 0 || chunk->n_buffers != 1)
    return fail(t, "a root struct array that breaks the specification", NULL);
  putf(t, "chunk %lld", (long long)k);
  putf(t, " rows %lld\n", (long long)chunk->length);
  for (int64_t c = 0; c < chunk->n_children; c++) {
    const struct ArrowArray *col = chunk->children[c];
    const struct ArrowSchema *f = schema->children[c];
    if (col->length != chunk->length)
      return fail(t, "a column whose length is not the chunk's", f->name);
    if (col->null_count > 0 && col->buffers[0] == NULL)
      return fail(t, "a column with nulls and no validity buffer", f->name);
    puts_(t, f->name);
    puts_(t, ":");
    for (int64_t i = 0; i < col->length; i++) {
      puts_(t, i == 0 ? " " : ", ");
      if (put_value(t, f, col, i) != 0) return 1;
    }
    puts_(t, "\n");
  }
  return 0;
}

static int put_schema(text *t, const struct ArrowSchema *schema) {
  if (strcmp(schema->format, "+s") != 0)
    return fail(t, "the stream's schema is not a struct", schema->format);
  for (int64_t c = 0; c < schema->n_children; c++) {
    const struct ArrowSchema *f = schema->children[c];
    puts_(t, "field ");
    puts_(t, f->name);
    puts_(t, " ");
    puts_(t, f->format);
    puts_(t, (f->flags & ARROW_FLAG_NULLABLE) ? " nullable\n" : " required\n");
  }
  return 0;
}

/* After a failure: release every chunk from `from` on and the schema, so a
 * refused stream leaks nothing either. */
static void release_rest(struct ArrowArray *chunks, int from, int n, struct ArrowSchema *schema) {
  for (int k = from; k < n; k++)
    if (chunks[k].release != NULL) chunks[k].release(&chunks[k]);
  if (schema->release != NULL) schema->release(schema);
}

static int consume(text *t, struct ArrowArrayStream *stream, int32_t mode) {
  if (stream->release == NULL) return fail(t, "the stream is already released", NULL);
  if (mode == 1) return release_stream(t, stream);

  struct ArrowSchema schema;
  memset(&schema, 0, sizeof schema);
  int rc = stream->get_schema(stream, &schema);
  if (rc != 0) {
    fail(t, "get_schema failed", stream->get_last_error(stream));
    release_stream(t, stream);
    return 1;
  }
  if (schema.release == NULL) {
    release_stream(t, stream);
    return fail(t, "get_schema returned a released schema", NULL);
  }

  struct ArrowArray chunks[MAX_CHUNKS];
  int n = 0;
  int wanted = mode == 2 ? 1 : MAX_CHUNKS;
  while (n < wanted) {
    memset(&chunks[n], 0, sizeof chunks[n]);
    rc = stream->get_next(stream, &chunks[n]);
    if (rc != 0) {
      /* The stream stays live: the caller releases it. */
      fail(t, "get_next failed", stream->get_last_error(stream));
      release_rest(chunks, 0, n, &schema);
      return 1;
    }
    if (chunks[n].release == NULL) break;
    n++;
  }
  if (n == MAX_CHUNKS) {
    release_rest(chunks, 0, n, &schema);
    return fail(t, "more chunks than this consumer holds", NULL);
  }

  /* The stream goes first: every chunk must outlive it. */
  if (release_stream(t, stream) != 0 || put_schema(t, &schema) != 0) {
    release_rest(chunks, 0, n, &schema);
    return 1;
  }
  for (int k = 0; k < n; k++) {
    if (put_chunk(t, &schema, &chunks[k], k) != 0) {
      release_rest(chunks, k, n, &schema);
      return 1;
    }
    if (release_array(t, &chunks[k]) != 0) {
      release_rest(chunks, k + 1, n, &schema);
      return 1;
    }
  }
  return release_schema(t, &schema);
}

int32_t komira_test_arrow_c_consume(struct ArrowArrayStream *stream, int32_t mode, char *out,
                                    int64_t cap, int64_t *out_len) {
  text t = {out, cap, 0, 0};
  int rc = consume(&t, stream, mode);
  if (t.overflow) {
    rc = fail(&t, "the text is longer than the buffer", NULL);
    t.overflow = 0;
  }
  *out_len = t.len;
  return rc;
}
