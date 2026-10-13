/*
 * komira-test/echo, part five: admission, validate and load (design section
 * 3.1, "Every descriptor records the signature, so validate stays pure",
 * and section 4.3 items 3 and 4). Included once, by echo_runtime.c, which
 * holds the fixtures, handles and errors this part uses; not a header of its
 * own.
 *
 *   - validate compares the spec with the descriptor alone (the shared
 *     decoder, native/spike_descriptor.c): the descriptor version, its
 *     canonical bytes, the entry, the shape, the signature and, for ROW and
 *     MAP_BATCHES_FRAME, the recorded fields (ERR_DESCRIPTOR, or
 *     ERR_READ_SET_MISMATCH for names that differ). A descriptor with no
 *     recorded fields skips that check (this runtime reads a row by name,
 *     lazily). It never looks at FIXTURES, which stand for the code.
 *   - load runs the same comparison, then opens the code: the fixture of
 *     the entry, which must agree with the descriptor's shapes and signature
 *     (ERR_LOAD otherwise), and binds the spec's schemas to it.
 */

static const struct fixture* find(const char* entry) {
  if (entry == NULL) return NULL;
  for (size_t i = 0; i < N_FIXTURES; i++)
    if (strcmp(FIXTURES[i].entry, entry) == 0) return &FIXTURES[i];
  return NULL;
}

static int leaf_is(const struct ArrowSchema* s, char f) {
  return s != NULL && s->release != NULL && s->format != NULL && s->format[0] == f && s->format[1] == 0 &&
         s->n_children == 0;
}

static int struct_is(const struct ArrowSchema* s, const char* fmts) {
  if (s == NULL || s->release == NULL || s->format == NULL || strcmp(s->format, "+s") != 0) return 0;
  if (s->n_children != (int64_t)strlen(fmts)) return 0;
  for (int64_t i = 0; i < s->n_children; i++)
    if (!leaf_is(s->children[i], fmts[i])) return 0;
  return 1;
}

/* A ROW read set: up to ROW_FIELDS_MAX int64 fields, each named, no name
 * twice; none at all is legal (a read set that is empty, design 3.4 rule 5). */
static int row_args_ok(const struct ArrowSchema* s) {
  if (s == NULL || s->format == NULL || strcmp(s->format, "+s") != 0) return 0;
  if (s->n_children < 0 || s->n_children > ROW_FIELDS_MAX) return 0;
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema* c = s->children[i];
    if (!leaf_is(c, FMT_I64) || c->name == NULL || c->name[0] == 0) return 0;
    for (int64_t j = 0; j < i; j++)
      if (strcmp(s->children[j]->name, c->name) == 0) return 0;
  }
  return 1;
}

/* A recorded field holds the one-character format `f`. */
static int field_is(const komira_udf_spike_field* x, char f) {
  return x->format_len == 1 && x->format[0] == (uint8_t)f;
}

/* validate: the spec against its descriptor; *d gets the descriptor. */
static int32_t admit(const komira_udf_host* h, const komira_udf_spec* s, komira_udf_spike_descriptor* d,
                     komira_udf_error* e) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(h, e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's", -1);
  if (s->form < KOMIRA_UDF_FORM_PACKAGE || s->form > KOMIRA_UDF_FORM_VALUE)
    return fail(h, e, KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE", -1);
  char why[640];
  int32_t rc = komira_udf_spike_descriptor_check(s, 0, d, why, sizeof(why));
  if (rc != KOMIRA_UDF_OK) return fail(h, e, rc, why, -1);
  return KOMIRA_UDF_OK;
}

/* load's check of the code (the fixture) against the descriptor. */
static int32_t code_agrees(const komira_udf_host* h, const struct fixture* fx, const komira_udf_spike_descriptor* d,
                           komira_udf_error* e) {
  char msg[256];
  if (d->shapes != fx->shape) {
    snprintf(msg, sizeof(msg), "the code's entry supports shape bits %u, the descriptor records %u", fx->shape,
             d->shapes);
    return fail(h, e, KOMIRA_UDF_ERR_LOAD, msg, -1);
  }
  int by_name = (fx->shape & (KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME)) != 0;
  int args_ok = by_name || d->n_args == strlen(fx->args);
  for (size_t i = 0; args_ok && !by_name && i < d->n_args; i++) args_ok = field_is(&d->args[i], fx->args[i]);
  int table = fx->result[0] == 't';
  const char* res = table ? fx->result + 1 : fx->result;
  int result_ok = table == d->result_is_table && d->n_result == strlen(res);
  for (size_t i = 0; result_ok && i < d->n_result; i++) result_ok = field_is(&d->result[i], res[i]);
  int state_ok = fx->state[0] == 0 ? !d->has_state : (d->has_state && field_is(&d->state, fx->state[0]));
  if (!args_ok || !result_ok || !state_ok) {
    snprintf(msg, sizeof(msg), "the code's signature differs from the descriptor's (%s)",
             !args_ok ? "arg_types" : !result_ok ? "return_type" : "state_type");
    return fail(h, e, KOMIRA_UDF_ERR_LOAD, msg, -1);
  }
  return KOMIRA_UDF_OK;
}

static int32_t echo_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  komira_udf_spike_descriptor d;
  return admit(rt->host, s, &d, e);
}

static int32_t echo_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out,
                         komira_udf_error* e) {
  komira_udf_spike_descriptor d;
  int32_t rc = admit(rt->host, s, &d, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  const struct fixture* fx = find(s->entry);
  if (fx == NULL) {
    char msg[200];
    snprintf(msg, sizeof(msg), "no code object holds the entry '%s'", s->entry);
    return fail(rt->host, e, KOMIRA_UDF_ERR_LOAD, msg, -1);
  }
  rc = code_agrees(rt->host, fx, &d, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  int result_ok = fx->result[0] == 't' ? struct_is(s->result, fx->result + 1) : leaf_is(s->result, fx->result[0]);
  int state_ok = fx->state[0] == 0 ? s->state == NULL : leaf_is(s->state, fx->state[0]);
  int args_ok = fx->args[0] == '*' ? row_args_ok(s->args) : struct_is(s->args, fx->args);
  if (!args_ok || !result_ok || !state_ok)
    return fail(rt->host, e, KOMIRA_UDF_ERR_LOAD, "the code cannot bind the spec's schemas", -1);
  /* the bug: a schema the host only lends, released (and a host release
   * that leaves its slot set refused) */
  if (fx->id == F_RELEASE_SCHEMA) {
    struct ArrowSchema* lent =
        (struct ArrowSchema*)(fx->variant == RS_RESULT ? s->result : fx->variant == RS_STATE ? s->state : s->args);
    lent->release(lent);
    if (lent->release != NULL)
      return fail(rt->host, e, KOMIRA_UDF_ERR_INTERNAL, "release_schema: the schema's release left its slot set", -1);
  }
  komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(rt->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory", -1);
  u->fx = fx;
  u->host = rt->host;
  u->n_args = s->args != NULL ? s->args->n_children : 0;
  u->flags[0] = s->args->flags;
  u->flags[1] = s->args->n_children > 0 ? s->args->children[0]->flags : -1;
  u->flags[2] = s->result->flags;
  if (fx->shape == KOMIRA_UDF_SHAPE_ROW) {
    for (int64_t i = 0; i < s->args->n_children; i++) {
      u->fields[i] = dup(s->args->children[i]->name);
      u->n_fields = i + 1;
      if (u->fields[i] == NULL) break;
    }
  }
  hold(u->host, sizeof(*u));
  *out = u;
  return KOMIRA_UDF_OK;
}

static void echo_unload(komira_udf_udf* u) {
  for (int64_t i = 0; i < u->n_fields; i++) free(u->fields[i]);
  drop(u->host, sizeof(*u));
  free(u);
}
