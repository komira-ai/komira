/*
 * komira-test/echo, part two: call_batch (SCALAR, ROW, MAP_BATCHES_COLUMN).
 * Included once, by echo_runtime.c, which holds the fixtures, handles,
 * errors and output builders this part uses; not a header of its own.
 */

/* ---- ROW: a row view over the read set ---------------------------------- */

/* One row's view: reads a field by name from the argument struct's children,
 * which are the read set in order. A name outside the read set records the
 * violation (the first one) and reads as 0; call_batch checks the record
 * before it returns, so user code that catches the error still fails the
 * batch. */
struct row_view {
  const struct komira_udf_udf* udf;
  const struct ArrowArray* args;
  int64_t row;
  const char* violation; /* the first undeclared name read, or NULL */
  int64_t violation_row;
};

static int64_t row_get(struct row_view* v, const char* name) {
  for (int64_t i = 0; i < v->udf->n_fields; i++)
    if (strcmp(v->udf->fields[i], name) == 0) return i64_at(v->args->children[i], v->row);
  if (v->violation == NULL) {
    v->violation = name;
    v->violation_row = v->row;
  }
  return 0;
}

static int32_t row_violation(const komira_udf_host* h, const struct row_view* v, komira_udf_error* e) {
  char msg[256];
  size_t at = (size_t)snprintf(msg, sizeof(msg), "field '%s' is not in the read set {", v->violation);
  for (int64_t i = 0; i < v->udf->n_fields && at < sizeof(msg); i++)
    at += (size_t)snprintf(msg + at, sizeof(msg) - at, "%s%s", i ? ", " : "", v->udf->fields[i]);
  if (at < sizeof(msg)) snprintf(msg + at, sizeof(msg) - at, "}; add it to columns=[...]");
  return fail(h, e, KOMIRA_UDF_ERR_FIELD_NOT_DECLARED, msg, v->violation_row);
}

/* pick and pick_caught over every row: `o` gets one int64 per row. */
static int32_t row_call(komira_udf_instance* inst, const struct ArrowArray* in, struct ArrowArray* o,
                        komira_udf_error* e) {
  const komira_udf_host* h = host_of(inst);
  uint8_t* valid;
  void* d;
  if (!make_col(h, o, in->length, &valid, &d))
    return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", -1);
  struct row_view v = {inst->udf, in, 0, NULL, -1};
  for (int64_t r = 0; r < in->length; r++) {
    v.row = r;
    const char* violation_before = v.violation;
    int64_t y = row_get(&v, "flag") ? row_get(&v, "a") : row_get(&v, "b");
    if (v.violation != violation_before && inst->fx->id == F_PICK) {
      /* The fixture lets the error propagate: the batch fails here. */
      release_array(o);
      return row_violation(h, &v, e);
    }
    ((int64_t*)d)[r] = y; /* pick_caught: the caught error leaves 0 */
  }
  if (v.violation != NULL && !BROKEN) { /* BROKEN (7) */
    release_array(o);
    return row_violation(h, &v, e);
  }
  return KOMIRA_UDF_OK;
}

/* ---- the column fixtures ------------------------------------------------- */

/* `in` is the argument struct; `o` the result. */
static int32_t scalar(komira_udf_instance* inst, const komira_udf_call* call, const struct ArrowArray* in,
                      struct ArrowArray* o, komira_udf_error* e) {
  const struct fixture* fx = inst->fx;
  const komira_udf_rt* rt = inst->ctx->rt;
  const komira_udf_host* h = rt->host;
  int64_t n = in->length;
  const struct ArrowArray* x = in->n_children > 0 ? in->children[0] : NULL;
  const struct ArrowArray* y = in->n_children > 1 ? in->children[1] : NULL;
  int64_t rows = (fx->id == F_SHORT_BY_ONE && n > 0) ? n - 1 : fx->id == F_LONG_BY_ONE ? n + 1 : n;
  if (fx->id == F_DOUBLE_STRICT || fx->id == F_ADD_STRICT)
    for (int64_t r = 0; r < n; r++)
      if (!is_valid(x, r) || (y != NULL && !is_valid(y, r)))
        return fail(h, e, KOMIRA_UDF_ERR_RAISED, "a strict fixture got a null argument", r);
  if (fx->id == F_RAISE_ON_ROW_3 && n > 3) return fail(h, e, KOMIRA_UDF_ERR_RAISED, "raise_on_row_3: row 3", 3);
  uint8_t* v;
  void* d;
  if (!make_col(h, o, rows, &v, &d)) return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", -1);
  int64_t* di = (int64_t*)d;
  for (int64_t r = 0; r < rows; r++) {
    if (fx->id == F_SLOW_LOOP) {
      if (cancelled(call)) {
        release_array(o);
        return fail(h, e, KOMIRA_UDF_ERR_CANCELLED, "slow_loop: cancelled", r);
      }
      if (past_deadline(rt, call)) {
        release_array(o);
        return fail(h, e, KOMIRA_UDF_ERR_DEADLINE, "slow_loop: deadline passed", r);
      }
      /* Each row waits SLOW_ROW_NS of the host's clock, or until the flag
       * is set; a cancel set during the call is seen at the next row. */
      int64_t until = h->now_ns(h->host_data) + SLOW_ROW_NS;
      while (h->now_ns(h->host_data) < until && !cancelled(call)) {
      }
    }
    di[r] = 0;
    if (r >= n) continue; /* long_by_one's extra row */
    if (fx->id == F_CONST7) {
      di[r] = 7;
      continue;
    }
    if (fx->id == F_NULL_OUT || !is_valid(x, r) || (fx->id == F_NULL_ON_ZERO && i64_at(x, r) == 0)) {
      set_null(o, v, r);
      continue;
    }
    switch (fx->id) {
      case F_FAHRENHEIT: {
        double t = f64_at(x, r) * 1.8 + 32.0;
        if (BROKEN)
          di[r] = (int64_t)t; /* BROKEN (2) */
        else
          ((double*)d)[r] = t;
        break;
      }
      case F_DOUBLE:
        di[r] = 2 * i64_at(x, r) + (BROKEN ? inst->calls : 0); /* BROKEN (6) */
        break;
      case F_DOUBLE_STRICT:
      case F_NULL_ON_ZERO:
        di[r] = 2 * i64_at(x, r);
        break;
      case F_ADD_STRICT:
        di[r] = i64_at(x, r) + i64_at(y, r);
        break;
      case F_NARROW:
        ((int32_t*)d)[r] = (int32_t)i64_at(x, r);
        break;
      default: /* identity and the identities with a bug */
        di[r] = i64_at(x, r);
    }
  }
  if (fx->id == F_BAD_LAYOUT) o->n_buffers = 1;
  inst->calls++;
  return KOMIRA_UDF_OK;
}

/* ---- leaf outputs reshaped ----------------------------------------------- */

#define SLICE_AT 11 /* not a multiple of 8: the bitmap's bits are shifted too */

/* The column `o` again at offset SLICE_AT: the SLICE_AT rows before it hold
 * PAD_VALUE with null bits, so a reader that ignores the offset reads nulls
 * and padding. */
static int32_t slice_leaf(const komira_udf_host* h, struct ArrowArray* o, komira_udf_error* e) {
  struct ArrowArray s;
  uint8_t* v;
  void* d;
  int64_t n = o->length;
  if (!make_col(h, &s, SLICE_AT + n, &v, &d)) {
    release_array(o);
    return fail(h, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "leaf_sliced: out of memory", -1);
  }
  s.null_count = 0;
  for (int64_t r = 0; r < SLICE_AT + n; r++) {
    int pad = r < SLICE_AT;
    ((int64_t*)d)[r] = pad ? PAD_VALUE : i64_at(o, r - SLICE_AT);
    if (pad || !is_valid(o, r - SLICE_AT)) {
      v[r >> 3] &= (uint8_t)~(1u << (r & 7));
      if (!pad) s.null_count++;
    }
  }
  s.offset = SLICE_AT;
  s.length = n;
  release_array(o);
  *o = s;
  return KOMIRA_UDF_OK;
}

static void release_keeps_slot(struct ArrowArray* a) { free_col(a); } /* the bug: `release` stays set */

static struct ArrowArray NOT_A_DICTIONARY; /* never read: the host refuses first */

/* F_LEAF: reshape the identity's output `out` by the fixture's variant. */
static int32_t reshape_leaf(const komira_udf_host* h, int shape, struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct ArrowArray* o = &out->array;
  switch (shape) {
    case LS_SLICED:
      return slice_leaf(h, o, e);
    case LS_NULL_COUNT_UNKNOWN:
      o->null_count = -1;
      break;
    case LS_EMPTY_DATA_NULL:
      if (o->length == 0) ((struct col_block*)o->private_data)->bufs[1] = NULL;
      break;
    case LS_N_BUFFERS_3:
      o->n_buffers = 3;
      break;
    case LS_N_CHILDREN_1:
      o->n_children = 1;
      break;
    case LS_DICTIONARY:
      o->dictionary = &NOT_A_DICTIONARY;
      break;
    /* null_count -1 with both: a reader that skips the check then has no
     * null count to trip over, and must read a wrong column. */
    case LS_NEGATIVE_LENGTH:
      o->length = -1;
      o->null_count = -1;
      break;
    case LS_NEGATIVE_OFFSET:
      o->offset = -1;
      o->null_count = -1;
      break;
    case LS_NULL_COUNT_BELOW:
      o->null_count = -2;
      break;
    case LS_BUFFERS_NULL:
      o->buffers = NULL;
      break;
    case LS_DATA_NULL:
      ((struct col_block*)o->private_data)->bufs[1] = NULL;
      break;
    case LS_RELEASE_KEEPS_SLOT:
      o->release = release_keeps_slot;
      break;
    case LS_DEVICE_ID:
      out->device_id = 0;
      break;
    case LS_SYNC_EVENT:
      out->sync_event = &NOT_A_DICTIONARY;
      break;
    default:
      break;
  }
  return KOMIRA_UDF_OK;
}

/* ---- call_batch ---------------------------------------------------------- */

static int32_t echo_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                               struct ArrowDeviceArray* out, komira_udf_error* e) {
  const komira_udf_host* h = host_of(inst);
  if (inst->fx->id == F_ARGS_KEPT) { /* the bug: args read in place, never moved */
    out->array.release = NULL;
    if (inst->fx->variant == KEPT_THEN_RAISE)
      return fail(h, e, KOMIRA_UDF_ERR_RAISED, "args_kept_raise: raised with args never moved", -1);
    int32_t kept = scalar(inst, call, &args->array, &out->array, e);
    if (kept == KOMIRA_UDF_OK) set_cpu(out);
    return kept;
  }
  struct ArrowDeviceArray mine = *args; /* moved in, whatever the status */
  args->array.release = NULL;
  out->array.release = NULL;
  int32_t rc = start_call(inst->ctx->rt, call, e);
  if (rc == KOMIRA_UDF_OK) rc = check_args(h, &mine.array, e);
  if (rc == KOMIRA_UDF_OK && mine.device_type != ARROW_DEVICE_CPU)
    rc = fail(h, e, KOMIRA_UDF_ERR_UNSUPPORTED, "only CPU arrays are read here", -1);
  if (rc == KOMIRA_UDF_OK &&
      (inst->fx->shape & (KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN)) == 0)
    rc = fail(h, e, KOMIRA_UDF_ERR_UNSUPPORTED, "call_batch on a fixture of another shape", -1);
  if (rc == KOMIRA_UDF_OK && inst->fx->shape == KOMIRA_UDF_SHAPE_ROW)
    rc = row_call(inst, &mine.array, &out->array, e);
  else if (rc == KOMIRA_UDF_OK)
    rc = scalar(inst, call, &mine.array, &out->array, e);
  if (rc == KOMIRA_UDF_OK) set_cpu(out);
  if (rc == KOMIRA_UDF_OK) {
    switch (inst->fx->id) { /* the runtime bugs of the fixtures above */
      case F_OUT_SET_ON_ERROR:
        rc = fail(h, e, KOMIRA_UDF_ERR_RAISED, "out_set_on_error: raised with out still set", -1);
        break;
      case F_OK_WITHOUT_OUTPUT:
        release_array(&out->array);
        break;
      case F_DEVICE_NOT_CPU:
        out->device_type = ARROW_DEVICE_CUDA;
        break;
      case F_NULL_COUNT_LIES:
        out->array.null_count += 1;
        break;
      case F_LEAF:
        rc = reshape_leaf(h, inst->fx->variant, out, e);
        break;
      case F_LEAK_RESERVATION:
        h->mem_reserve(h->host_data, 64);
        break;
      case F_ERROR_ON_OK: /* an error filled, then OK returned: the host still releases it */
        fail(h, e, KOMIRA_UDF_ERR_RAISED, "error_on_ok: filled, then OK returned", -1);
        break;
      case F_RAISE_NO_MESSAGE: /* an error code with no message and nothing to release */
        release_array(&out->array);
        e->code = KOMIRA_UDF_ERR_RAISED;
        rc = KOMIRA_UDF_ERR_RAISED;
        break;
      default:
        break;
    }
  }
  if (inst->fx->id == F_RELEASE_ARGS_TWICE && mine.array.release != NULL) {
    void (*rel)(struct ArrowArray*) = mine.array.release;
    rel(&mine.array);
    rel(&mine.array); /* the bug */
  }
  if (!(BROKEN && rc == KOMIRA_UDF_ERR_RAISED)) release_array(&mine.array); /* BROKEN (1) */
  return rc;
}
