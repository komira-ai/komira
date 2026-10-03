# komira_libc

The libc and POSIX layer every package shares: one getenv, the access probes and pthread_self, file and memory-map syscall wrappers with the C shim symbols they call, chunked large writes, RAII file descriptor.
