/* A C host of libkomira, written against komira.h only.
 *
 * It opens ./libkomira.so with RTLD_NOW and binds every function the header
 * declares to the symbol of that name. Each pointer is declared with the type
 * of the header's prototype (`__typeof__`), so the calls below are compiled
 * against the header and run against the binary. A header whose version, status
 * codes or argument types differ from the library's fails here.
 *
 * Exit 0 only if every check holds; each failure prints one line. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#include "komira.h"

static int failures = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond);          \
            failures++;                                                      \
        }                                                                    \
    } while (0)

#define DECLARE(name) static __typeof__(name) *p_##name

DECLARE(komira_abi_version);
DECLARE(komira_ctx_new);
DECLARE(komira_ctx_free);
DECLARE(komira_last_error);
DECLARE(komira_register_parquet);
DECLARE(komira_parquet_schema);
DECLARE(komira_csv_binding);
DECLARE(komira_json_binding);
DECLARE(komira_plan_render);

static int bind_all(void *lib) {
    int missing = 0;
#define BIND(name)                                                           \
    do {                                                                     \
        void *sym = dlsym(lib, #name);                                       \
        if (sym == NULL) {                                                   \
            fprintf(stderr, "MISSING EXPORT: %s\n", #name);                  \
            missing++;                                                       \
        }                                                                    \
        memcpy(&p_##name, &sym, sizeof sym);                                 \
    } while (0)
    BIND(komira_abi_version);
    BIND(komira_ctx_new);
    BIND(komira_ctx_free);
    BIND(komira_last_error);
    BIND(komira_register_parquet);
    BIND(komira_parquet_schema);
    BIND(komira_csv_binding);
    BIND(komira_json_binding);
    BIND(komira_plan_render);
#undef BIND
    return missing;
}

/* The status codes are part of the header; the binary must agree on each. */
_Static_assert(KOMIRA_OK == 0, "KOMIRA_OK");
_Static_assert(KOMIRA_ERR_NULL_CTX == -1, "KOMIRA_ERR_NULL_CTX");
_Static_assert(KOMIRA_ERR_NULL_ARG == -2, "KOMIRA_ERR_NULL_ARG");
_Static_assert(KOMIRA_ERR_ENGINE == -3, "KOMIRA_ERR_ENGINE");
_Static_assert(KOMIRA_ERR_BUFFER_TOO_SMALL == -4, "KOMIRA_ERR_BUFFER_TOO_SMALL");
_Static_assert(KOMIRA_ERR_TOO_LARGE == -5, "KOMIRA_ERR_TOO_LARGE");
_Static_assert(KOMIRA_MAX_INPUT_BYTES == 64 * 1024 * 1024, "KOMIRA_MAX_INPUT_BYTES");

int main(void) {
    void *lib = dlopen("./libkomira.so", RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    if (bind_all(lib) != 0) return 1;

    /* The version in the header is the version of the binary. */
    CHECK(p_komira_abi_version() == KOMIRA_ABI_VERSION_MAJOR * 1000 + KOMIRA_ABI_VERSION_MINOR);

    /* A context is a handle; two are two sessions. */
    komira_handle ctx = p_komira_ctx_new();
    komira_handle other = p_komira_ctx_new();
    CHECK(ctx != NULL && other != NULL && ctx != other);

    /* A fresh session has no error: the length is 0 and no buffer is needed. */
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK);
    CHECK(len == 0);

    /* The statuses the header names are the ones the binary returns. */
    CHECK(p_komira_last_error(NULL, NULL, 0, &len) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_last_error(ctx, NULL, 0, NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_register_parquet(NULL, "t", "x.parquet") == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_register_parquet(ctx, NULL, "x.parquet") == KOMIRA_ERR_NULL_ARG);

    /* An engine refusal stores its text in the context: the two-call round trip. */
    CHECK(p_komira_register_parquet(ctx, "t", "no_such_file.parquet") == KOMIRA_ERR_ENGINE);
    len = 0;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_ERR_BUFFER_TOO_SMALL);
    CHECK(len > 0 && len < 4096);
    uint8_t text[4096];
    uint64_t again = 0;
    memset(text, 0, sizeof text);
    CHECK(p_komira_last_error(ctx, text, len - 1, &again) == KOMIRA_ERR_BUFFER_TOO_SMALL);
    CHECK(again == len && text[0] == 0); /* a short buffer is not written */
    CHECK(p_komira_last_error(ctx, text, len, &again) == KOMIRA_OK);
    CHECK(again == len && text[0] != 0 && text[len] == 0);
    /* The other session saw none of it. */
    CHECK(p_komira_last_error(other, NULL, 0, &len) == KOMIRA_OK && len == 0);

    /* A path that is not a file is the engine's refusal for each source call. */
    uint8_t out[16];
    uint64_t out_len = 0;
    CHECK(p_komira_parquet_schema(ctx, "no_such_file.parquet", out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_csv_binding(ctx, "no_such_file.csv", ',', 1, 0, out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_json_binding(ctx, "no_such_file.json", out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);

    /* The input bound is the header's: one byte over is refused before any read. */
    static const uint8_t plan[1] = {0};
    CHECK(p_komira_plan_render(ctx, plan, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1, out, sizeof out, &out_len) == KOMIRA_ERR_TOO_LARGE);
    CHECK(p_komira_plan_render(ctx, plan, UINT64_MAX, out, sizeof out, &out_len) == KOMIRA_ERR_TOO_LARGE);
    CHECK(p_komira_plan_render(ctx, NULL, 0, NULL, 0, NULL) == KOMIRA_ERR_NULL_ARG);

    p_komira_ctx_free(ctx);
    p_komira_ctx_free(other);
    p_komira_ctx_free(NULL);
    return failures == 0 ? 0 : 1;
}
