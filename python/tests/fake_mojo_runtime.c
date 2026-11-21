// Stand-ins for the three Mojo runtime libraries, and for a library that
// needs them as libkomira does, for the runtime preload's tests
// (test_runtime.py). FAKE_LIB picks which one this build is:
//
// 1: libMSupportGlobals, which needs nothing.
// 2: libAsyncRTRuntimeGlobals, which needs a symbol of 1.
// 3: libKGENCompilerRTShared, which needs a symbol of 1 and one of 2.
// 4: the consumer, which needs a symbol of 3.
//
// Each reference is a data relocation, bound when the library is opened, and
// none is satisfied by a NEEDED entry or a run path: a library opens only if
// the libraries it needs are already open with RTLD_GLOBAL. So the four open
// only in the order 1, 2, 3, 4, and only with RTLD_GLOBAL for the first three.

#define EXPORT __attribute__((visibility("default")))

#if FAKE_LIB == 1
EXPORT int fake_msupport = 1;
#elif FAKE_LIB == 2
extern int fake_msupport;
EXPORT int *fake_asyncrt = &fake_msupport;
#elif FAKE_LIB == 3
extern int fake_msupport;
extern int *fake_asyncrt;
EXPORT void *fake_kgen[2] = {&fake_msupport, &fake_asyncrt};
#elif FAKE_LIB == 4
extern void *fake_kgen[2];
EXPORT void **fake_consumer = fake_kgen;
#else
#error "FAKE_LIB must be 1, 2, 3 or 4"
#endif
