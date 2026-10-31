/* The mopm manifest names a source for every [native.<id>] (mopm 0.0.86 has no entry for a library the
 * package does not compile). libsnappy.a is built by the native_library target //third_party/snappy:snappy_native
 * and named in BUCK's `natives = {...}`; this file is not compiled. */
