/*
 * komira-test/echo, part three: the mergeable aggregate (sum) and the frame
 * fixtures (running_sum, group_max, empty_table, and the frames with a bug).
 * Included once, by echo_runtime.c, which holds the fixtures, handles,
 * errors and output builders this part uses; not a header of its own.
 */

/* ---- mergeable aggregate: sum ------------------------------------------ */

static int32_t echo_agg_open(komira_udf_instance* inst, komira_udf_groups** out, komira_udf_error* e) {
  if (inst->fx->shape != KOMIRA_UDF_SHAPE_AGG_MERGEABLE)
    return fail(host_of(inst), e, KOMIRA_UDF_ERR_UNSUPPORTED, "agg_open on a fixture of another shape", -1);
  komira_udf_groups* g = calloc(1, sizeof(*g));
  if (g == NULL) return fail(host_of(inst), e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg_open: out of memory", -1);
  g->fx = inst->fx;
  g->host = host_of(inst);
  *out = g;
  return KOMIRA_UDF_OK;
}

static int grow(komira_udf_groups* g, uint32_t n) {
  if (n > g->cap) {
    uint32_t cap = g->cap ? g->cap : 16;
    while (cap < n) cap *= 2;
    int64_t* st = realloc(g->st, (size_t)cap * sizeof(int64_t));
    if (st == NULL) return 0;
    memset(st + g->cap, 0, (size_t)(cap - g->cap) * sizeof(int64_t));
    g->st = st;
    g->cap = cap;
  }
  if (n > g->n) g->n = n;
  return 1;
}

/* A copy of `a` the host still owns (a fixture's bug: the input read in
 * place and never moved): releasing the copy is a no-op. */
static struct ArrowDeviceArray borrowed(const struct ArrowDeviceArray* a) {
  struct ArrowDeviceArray view = *a;
  view.array.release = NULL;
  return view;
}

/* agg_update (`merge` 0: values are the argument struct's first child) and
 * agg_merge (`merge` 1: values are the state column). */
static int32_t fold(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* values,
                    struct ArrowDeviceArray* gids, uint32_t n_groups, komira_udf_error* e, int merge) {
  struct ArrowDeviceArray v = *values; /* both moved in */
  values->array.release = NULL;
  struct ArrowDeviceArray ids = *gids;
  gids->array.release = NULL;
  int32_t rc = KOMIRA_UDF_OK;
  const struct ArrowArray* x = merge ? &v.array : (v.array.n_children > 0 ? v.array.children[0] : NULL);
  int inputs_ok = column_ok(&ids.array) && (merge ? column_ok(&v.array) : args_ok(&v.array));
  if (!inputs_ok)
    rc = fail(g->host, e, KOMIRA_UDF_ERR_INTERNAL, "an aggregate input breaks the C Data rules", -1);
  else if (cancelled(call))
    rc = fail(g->host, e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch", -1);
  else if (x == NULL || ids.array.length != v.array.length)
    rc = fail(g->host, e, KOMIRA_UDF_ERR_INTERNAL, "group ids and values differ in length", -1);
  else if (!grow(g, n_groups))
    rc = fail(g->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg: out of memory", -1);
  for (int64_t r = 0; rc == KOMIRA_UDF_OK && r < v.array.length; r++) {
    int32_t gid = i32_at(&ids.array, r);
    if (gid < 0 || (uint32_t)gid >= n_groups) {
      rc = fail(g->host, e, KOMIRA_UDF_ERR_INTERNAL, "a group id is not below n_groups", r);
      break;
    }
    if (!is_valid(x, r)) continue;
    if (merge && BROKEN)
      g->st[gid] = i64_at(x, r); /* BROKEN (4) */
    else
      g->st[gid] += i64_at(x, r);
  }
  release_array(&v.array);
  release_array(&ids.array);
  return rc;
}

static int32_t echo_agg_update(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* args,
                               struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  if (g->fx->id == F_SUM_ARGS_KEPT) {
    struct ArrowDeviceArray view = borrowed(args);
    return fold(g, c, &view, gids, n, e, 0);
  }
  if (g->fx->id == F_SUM_GIDS_KEPT) {
    struct ArrowDeviceArray view = borrowed(gids);
    return fold(g, c, args, &view, n, e, 0);
  }
  return fold(g, c, args, gids, n, e, 0);
}

static int32_t echo_agg_merge(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* states,
                              struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  if (g->fx->id == F_SUM_MERGE_KEPT) {
    struct ArrowDeviceArray view = borrowed(states);
    return fold(g, c, &view, gids, n, e, 1);
  }
  return fold(g, c, states, gids, n, e, 1);
}

/* Emit the first `n` groups' sums and forget them: the groups after them
 * move down by `n` (the design does not say whether ids shift; here they
 * do). The column has n + `extra` rows (a fixture's bug when not 0): the
 * sums, then zeros. */
static int32_t emit(komira_udf_groups* g, uint32_t n, int64_t extra, struct ArrowDeviceArray* out,
                    komira_udf_error* e) {
  out->array.release = NULL;
  if (n > g->n) return fail(g->host, e, KOMIRA_UDF_ERR_INTERNAL, "emit_first_n is above the group count", -1);
  int64_t rows = (int64_t)n + extra < 0 ? 0 : (int64_t)n + extra;
  uint8_t* v;
  void* d;
  if (!make_col(g->host, &out->array, rows, &v, &d))
    return fail(g->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg: out of memory", -1);
  for (int64_t r = 0; r < rows; r++) ((int64_t*)d)[r] = r < (int64_t)n ? g->st[r] : 0;
  memmove(g->st, g->st + n, (size_t)(g->n - n) * sizeof(int64_t));
  g->n -= n;
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

static int32_t echo_agg_state(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return emit(g, n, g->fx->id == F_SUM_STATE_LONG ? 1 : 0, out, e);
}

static int32_t echo_agg_finish(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return emit(g, n, g->fx->id == F_SUM_FINISH_SHORT ? -1 : 0, out, e);
}

static void echo_agg_close(komira_udf_groups* g) {
  free(g->st);
  free(g);
}

/* ---- frames: running_sum, group_max (plain aggregate), empty_table (step) */

static int32_t echo_frame_open(komira_udf_instance* inst, const komira_udf_call* call,
                               struct ArrowDeviceArrayStream* in, komira_udf_frame** out, komira_udf_error* e) {
  struct ArrowDeviceArrayStream mine = *in; /* moved in, whatever the status */
  if (inst->fx->id == F_FRAME_IN_KEPT)
    mine.release = NULL; /* the bug: `in` read in place, never moved */
  else
    in->release = NULL;
  int32_t rc = KOMIRA_UDF_OK;
  if ((inst->fx->shape & (KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_STEP)) == 0)
    rc = fail(host_of(inst), e, KOMIRA_UDF_ERR_UNSUPPORTED, "frame_open on a fixture of another shape", -1);
  if (rc == KOMIRA_UDF_OK) rc = start_call(inst->ctx->rt, call, e);
  komira_udf_frame* fr = NULL;
  if (rc == KOMIRA_UDF_OK && (fr = calloc(1, sizeof(*fr))) == NULL)
    rc = fail(host_of(inst), e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "frame_open: out of memory", -1);
  if (rc != KOMIRA_UDF_OK) {
    if (mine.release != NULL) mine.release(&mine);
    return rc;
  }
  fr->inst = inst;
  fr->in = mine;
  fr->group = -1;
  *out = fr;
  return KOMIRA_UDF_OK;
}

/* The next input batch into *b; 0 with b->array.release == NULL at the end;
 * nonzero when the stream fails or hands out a batch that is not an
 * argument struct (args_ok), which is then released. */
static int pull(komira_udf_frame* fr, struct ArrowDeviceArray* b) {
  memset(b, 0, sizeof(*b));
  int rc = fr->in.get_next(&fr->in, b);
  if (rc == 0 && b->array.release != NULL && !args_ok(&b->array)) {
    release_array(&b->array);
    return -1;
  }
  return rc;
}

/* An n-row table with one int64 column, into `out`; the column's validity
 * and values through *v and *d. 0: out of memory, `out` released. */
static int one_column_table(const komira_udf_host* h, struct ArrowDeviceArray* out, int64_t n, uint8_t** v,
                            void** d) {
  if (!make_struct(&out->array, n, 1) || !make_col(h, out->array.children[0], n, v, d)) {
    release_array(&out->array);
    return 0;
  }
  return 1;
}

static int32_t next_running_sum(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(fr->inst);
  struct ArrowDeviceArray b;
  if (pull(fr, &b) != 0) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  if (b.array.release == NULL) {
    fr->done = 1;
    return KOMIRA_UDF_OK;
  }
  int64_t n = b.array.length;
  const struct ArrowArray* x = b.array.n_children > 0 ? b.array.children[0] : NULL;
  uint8_t* v;
  void* d;
  if (x == NULL || !one_column_table(h, out, n, &v, &d)) {
    release_array(&b.array);
    return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "running_sum: no input column, or out of memory", -1);
  }
  for (int64_t r = 0; r < n; r++) {
    if (!is_valid(x, r)) {
      ((int64_t*)d)[r] = 0;
      set_null(out->array.children[0], v, r);
      continue;
    }
    fr->running += i64_at(x, r);
    ((int64_t*)d)[r] = fr->running;
  }
  release_array(&b.array);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* Pulls until at least one group is complete (or the input ends), and
 * returns the completed groups' maxima, one row each, in ordinal order. */
static int32_t next_group_max(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(fr->inst);
  int64_t* done = NULL;
  int64_t k = 0, cap = 0;
  while (k == 0 && !fr->done) {
    struct ArrowDeviceArray b;
    if (pull(fr, &b) != 0) {
      free(done);
      return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
    }
    int64_t n = b.array.release == NULL ? 0 : b.array.length;
    if (b.array.release == NULL) fr->done = 1;
    if (n > 0 && b.array.n_children < 2) {
      release_array(&b.array);
      free(done);
      return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "group_max: a batch without its group and value columns", -1);
    }
    for (int64_t r = 0; r <= n; r++) {
      int at_end = r == n;
      if (at_end && !fr->done) break;
      int64_t gid = at_end ? -1 : i64_at(b.array.children[0], r);
      if (!at_end && gid == fr->group) {
        int64_t val = i64_at(b.array.children[1], r);
        if (val > fr->max) fr->max = val;
        continue;
      }
      if (fr->group >= 0) {
        if (k == cap) {
          cap = cap ? cap * 2 : 16;
          int64_t* grown = realloc(done, (size_t)cap * sizeof(int64_t));
          if (grown == NULL) {
            free(done);
            release_array(&b.array);
            return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "group_max: out of memory", -1);
          }
          done = grown;
        }
        done[k++] = fr->max;
      }
      fr->group = gid;
      if (!at_end) fr->max = i64_at(b.array.children[1], r);
    }
    release_array(&b.array);
  }
  if (k == 0) {
    free(done);
    return KOMIRA_UDF_OK; /* the end */
  }
  uint8_t* v;
  void* d;
  if (!make_col(h, &out->array, k, &v, &d)) {
    free(done);
    return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "group_max: out of memory", -1);
  }
  memcpy(d, done, (size_t)k * sizeof(int64_t));
  free(done);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* A step: one length-1 batch of literal arguments in; a table with no
 * columns and as many rows as the first literal says, out. */
static int32_t next_step(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(fr->inst);
  struct ArrowDeviceArray b;
  if (pull(fr, &b) != 0) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  fr->done = 1;
  if (b.array.release == NULL) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "a step got no literal batch", -1);
  int64_t rows = b.array.length == 1 && b.array.n_children == 1 ? i64_at(b.array.children[0], 0) : -1;
  release_array(&b.array);
  if (rows < 0) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "a step's literal batch is not one int64 row", -1);
  if (!make_struct(&out->array, rows, 0)) return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "step: out of memory", -1);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* yield_two_then_raise: the input batch is the output (a runtime may return
 * its input buffers), twice; then an error, with the rest unread. */
static int32_t next_yield_two(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(fr->inst);
  if (fr->running == 2) {
    fr->done = 1;
    return fail(h, e, KOMIRA_UDF_ERR_RAISED, "yield_two_then_raise: raised after two outputs", -1);
  }
  if (pull(fr, out) != 0) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  if (out->array.release == NULL) fr->done = 1;
  fr->running++;
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* endless: a one-row table on every call; it never ends. */
static int32_t next_endless(const komira_udf_host* h, struct ArrowDeviceArray* out, komira_udf_error* e) {
  uint8_t* v;
  void* d;
  if (!one_column_table(h, out, 1, &v, &d)) return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "endless: out of memory", -1);
  ((int64_t*)d)[0] = 0;
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

#define TABLE_AT 2 /* table_sliced: the struct's offset */
#define CHILD_AT 3 /* table_sliced: its child's own offset */

/* F_TABLE: each input batch's first column as a one-column table, reshaped
 * by the fixture's variant. table_sliced places the n rows at struct offset
 * TABLE_AT over a child of TABLE_AT + n rows at offset CHILD_AT; the rows
 * before them are PAD_VALUE with null bits, in the child and in the
 * struct's own validity bitmap. */
static int32_t next_table(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(fr->inst);
  int shape = fr->inst->fx->variant;
  struct ArrowDeviceArray b;
  if (pull(fr, &b) != 0) return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  if (b.array.release == NULL) {
    fr->done = 1;
    return KOMIRA_UDF_OK;
  }
  int64_t n = b.array.length;
  const struct ArrowArray* x = b.array.n_children > 0 ? b.array.children[0] : NULL;
  int64_t pad = shape == TS_SLICED ? CHILD_AT + TABLE_AT : 0;
  uint8_t* v;
  void* d;
  if (x == NULL || !one_column_table(h, out, pad + n, &v, &d)) {
    release_array(&b.array);
    return fail(h, e, KOMIRA_UDF_ERR_INTERNAL, "table: no input column, or out of memory", -1);
  }
  struct ArrowArray* c = out->array.children[0];
  for (int64_t r = 0; r < pad + n; r++) {
    int is_pad = r < pad;
    ((int64_t*)d)[r] = is_pad ? PAD_VALUE : i64_at(x, r - pad);
    if (is_pad || !is_valid(x, r - pad)) set_null(c, v, r);
  }
  release_array(&b.array);
  set_cpu(out);
  struct table_block* blk = (struct table_block*)out->array.private_data;
  switch (shape) {
    case TS_SLICED:
      c->offset = CHILD_AT;
      c->length = TABLE_AT + n;
      c->null_count -= CHILD_AT; /* the pad rows before the child's offset are not its rows */
      out->array.offset = TABLE_AT;
      out->array.length = n;
      /* A struct validity bitmap too: the TABLE_AT rows before the offset
       * are null, the struct's own rows valid (n <= 62 here). */
      memset(blk->validity, 0xFF, sizeof(blk->validity));
      for (int64_t r = 0; r < TABLE_AT; r++) blk->validity[r >> 3] &= (uint8_t)~(1u << (r & 7));
      blk->bufs[0] = blk->validity;
      break;
    case TS_N_BUFFERS_0:
      out->array.n_buffers = 0;
      break;
    case TS_N_BUFFERS_2:
      out->array.n_buffers = 2;
      break;
    case TS_N_CHILDREN_0:
      out->array.n_children = 0;
      break;
    case TS_N_CHILDREN_2:
      out->array.n_children = 2; /* view[1] is NULL */
      break;
    case TS_NEGATIVE_LENGTH:
      out->array.length = -1;
      break;
    case TS_NEGATIVE_OFFSET:
      out->array.offset = -1;
      break;
    case TS_BUFFERS_NULL:
      out->array.buffers = NULL;
      break;
    case TS_NULL_ROWS:
      memset(blk->validity, 0xFF, sizeof(blk->validity));
      blk->validity[0] &= (uint8_t)~1u;
      blk->bufs[0] = blk->validity;
      out->array.null_count = 1;
      break;
    case TS_NULL_COUNT_LIES:
      out->array.null_count = 1;
      break;
    case TS_CHILD_NULL:
      blk->view[0] = NULL;
      break;
    case TS_CHILD_RELEASED:
      c->release = NULL;
      break;
    case TS_CHILD_SHORT:
      c->length = n - 1;
      break;
    case TS_DEVICE:
      out->device_type = ARROW_DEVICE_CUDA;
      break;
    case TS_OUT_ON_ERROR:
      fr->done = 1;
      return fail(h, e, KOMIRA_UDF_ERR_RAISED, "table_out_on_error: raised with out still set", -1);
    default:
      break;
  }
  return KOMIRA_UDF_OK;
}

static int32_t echo_frame_next(komira_udf_frame* fr, const komira_udf_call* call, struct ArrowDeviceArray* out,
                               komira_udf_error* e) {
  out->array.release = NULL;
  if (cancelled(call)) return fail(host_of(fr->inst), e, KOMIRA_UDF_ERR_CANCELLED, "cancelled between batches", -1);
  if (fr->done) return KOMIRA_UDF_OK; /* the end: out->array.release stays NULL */
  switch (fr->inst->fx->id) {
    case F_RUNNING_SUM:
    case F_FRAME_IN_KEPT:
    case F_STREAM_KEPT:
      return next_running_sum(fr, out, e);
    case F_GROUP_MAX:
      return next_group_max(fr, out, e);
    case F_YIELD_TWO_THEN_RAISE:
      return next_yield_two(fr, out, e);
    case F_ENDLESS:
      return next_endless(host_of(fr->inst), out, e);
    case F_TABLE:
      return next_table(fr, out, e);
    default:
      return next_step(fr, out, e);
  }
}

static void echo_frame_close(komira_udf_frame* fr) {
  /* stream_kept: the bug, `in` never released */
  if (fr->in.release != NULL && fr->inst->fx->id != F_STREAM_KEPT) fr->in.release(&fr->in);
  free(fr);
}
