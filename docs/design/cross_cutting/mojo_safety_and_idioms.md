# Mojo safety and idioms: pointers, origins and the 1.0 spellings

## What is it for, and what is out of scope?

This doc explains how Mojo code in this repository keeps memory safe, and which spellings the pinned compiler requires. It is for anyone writing or reviewing a `.mojo` file here. It says what each rule protects, how the code follows it, and what holds it today.

The design rests on one idea: the compiler can only keep a value alive while it can see who borrows it. A Mojo reference carries an **origin**, the value it borrows from, and the compiler destroys a value right after its last use. A raw pointer with a concrete origin stays visible to that analysis; a pointer with a wildcard origin, or one made from an integer, does not. So raw pointers stay inside the module that owns the memory, and the public API speaks in values, references and views.

Out of scope:

- The build rules, the compiler pin and packaging: see [the Mojo rules](../../../tools/build/mojo/README.md) and [the toolchains](../../../tools/build/toolchains/README.md).
- The buffer, view and slab types themselves: see [columnar memory](../core/columnar_memory_and_arrow.md#what-do-the-collections-and-simd-kernels-provide).
- The worker pool that runs parallel work, which belongs to the async runtime.

## How does it work?

A Mojo package here exposes safe types and keeps its unsafe code private:

```
caller module                      owning module (e.g. komira_core.collections)
  value / ref [origin] T   ───►      struct with private raw storage
  ByteView[origin]         ◄───        UnsafePointer with a concrete origin
  OwnedPointer[T]                       + a `# SAFETY:` comment
```

### Which pointer type should I use?

Take the first of these that works:

1. **No pointer.** Pass a value, or `ref [origin] T` for a large one.
2. **`OwnedPointer[T]`**, one owner and a stable heap address, like Rust's `Box<T>`.
3. **`ArcPointer[T]`**, shared ownership through an atomic count, like Rust's `Arc<T>`, for a value that two scopes own with no common owner.
4. **`UnsafePointer[T]` with a concrete origin**, inside a struct or module only, with a `# SAFETY:` comment that says why the access is sound.

On the pinned compiler `Pointer` and `UnsafePointer` are one type, so the rules for one apply to the other.

### How do the collection types keep pointers private?

They lend views and references whose origin is the collection. `ByteView[origin]` in `src/komira_core/collections/byte_view.mojo` is parameterised on the origin of the bytes it views, so a view cannot outlive its source. `Slab[T]` in `src/komira_core/collections/slab.mojo` stores its elements in a `List[UInt8]` field, `_bytes`, and returns elements by reference or by move (`take_slot_unchecked`, `swap_remove`).

### How do I move a field out of a struct?

Use a primitive that ends the source's ownership on the record: `Optional.take()`, `OwnedPointer.take()`, the standard library's `swap(field, default)`, `List.pop()`, or `Slab.take_slot_*`. Taking a field's address and calling `take_pointee()` on it is a **partial move via a pointer**: the compiler still believes the field is live and destroys it again when the struct dies.

### How is work run in parallel?

Through a fork-join dispatcher, never through the standard library's `parallelize[`. `komira_core` defines the contract in `src/komira_core/runtime_traits/`: the `ParallelDispatch` trait, whose one method `run_with_state[State, T]` runs a closure over a shared state on the dispatcher's workers, and `fork_join_shared` (`fork_join_shared.mojo`), which splits work into chunks and runs them on a `ParallelDispatch` or inline. The async runtime supplies the real dispatcher. `NoDispatch` is a zero-sized serial stand-in: a caller with no dispatcher names it, and the branch that would call it is removed at compile time.

### How do I call a C function?

With `external_call`, from the module that owns the foreign resource, behind a safe function. The convention is a `# FFI-BOUNDARY:` comment that names the library and who owns and frees each pointer; 21 of the 46 non-test files under `src/` that call `external_call` carry one. Do not declare libc's `read` or `open` again: the Mojo standard library already binds both, and a second declaration with a different signature fails to lower on Linux only. When a call depends on platform constants, put it in a C shim instead: `MmapRegion.open_readonly` in `src/komira_core/io/mmap_region.mojo` calls the C shim `komira_open_ro` (`src/komira_core/native/komira_core_posix.c`), which calls `openat` with the platform's own `AT_FDCWD` (-2 on macOS, -100 on Linux).

### Which Mojo 1.0 spellings does the compiler require?

The toolchain pins Mojo `1.0.0` (the `mojo-compiler` packages in `tools/build/toolchains/BUCK`). Each of these is a compile error on it, so the compiler enforces the rule; the right-hand column says how to choose among the fixes.

| You write | 1.0.0 wants | Choosing |
|---|---|---|
| `len(s)` on a `String` or `StringSlice` | `s.byte_length()`, `len(s.codepoints())` or `len(s.graphemes())` | Bytes for buffers and offsets, code points or graphemes for text shown to people. |
| an implicit copy of an `InlineArray[T, N]` | `x^` or `x.copy()` | `^` when the value is dead afterwards (a `return` or a hand-off); `.copy()` when it is read later, with a comment naming that read. |
| an implicit `Int` to `UInt8` (or other sized integer) conversion at a call | an explicit `UInt8(x)`, `Int(x)` | The conversion is removed in both directions. |
| `x = String(x[byte=0:n])`, a value rebound to a slice of itself | an owned temporary: `var t = String(x[byte=0:n])`, then `x = t^` | The compiler refuses to borrow a value and construct into it in one call; the temporary adds no allocation. |
| `mut self: Slab[_T]` to refine a method's receiver | `where conforms_to(Self.T, Movable)` after the signature | The diagnostic names a `where` clause but not this spelling. |
| `ref [self._rows]` on a method that returns `self._rows[i]` | `ref [origin_of(self._rows[i])]` | The origin of an element differs from the origin of its container field; the diagnostic prints a notation that is not accepted as input. |
| `sys.env_get_string` | a per-site decision | It is deleted. It read a compile-time `-D` define, so `os.getenv`, a run-time read, is a different program. |

## Why is it built this way?

### Why must a raw pointer stay inside one module?

**Decision.** A public function takes and returns no pointer type; raw pointer arithmetic lives in one struct or module behind `get`, `set` and index operations.

**Because.** A pointer in a signature moves the arithmetic to every caller, so the same offset logic is written, and can be wrong, in N places instead of one. A typed view or reference carries its origin, so the compiler keeps the source alive for as long as the caller holds it.

**Alternatives weighed.**

- A pointer in the signature with a concrete origin: the origin keeps the memory alive, but every caller still repeats the arithmetic and its bounds checks.

**Revisit if.** Mojo gains a checked slice or span type that covers these uses with no copy; the rule would then collapse to "use it".

### Why are wildcard origins banned?

**Decision.** A pointer is not given the origins `MutAnyOrigin`, `ImmutAnyOrigin` or `MutExternalOrigin` (or its Mojo 1.1 name `MutUntrackedOrigin`, which the pinned compiler also accepts), and it is not made from an integer with `unsafe_from_address=`.

**Because.** A wildcard origin tells the compiler nothing about which value the memory belongs to, so the compiler may destroy that value before the last read through the pointer. The typical failure: a struct with a heap-owning field (a `List`, a `String`) stored in a byte-backed slab through a wildcard pointer. The compiler frees the inner buffer while the struct is still in use, and the next read returns freed allocator bytes and crashes. A struct field of wildcard type is worse on destroy-and-recreate cycles, because the allocator hands the old bytes to the next object.

**Alternatives weighed.**

- Treat it as a compiler bug: the crash follows from the cast, and it reproduces on the pinned compiler.
- Keep the value alive with `_ = value`: the compiler may still move the destruction, so it is not a guarantee.

**Revisit if.** Mojo can express the origin of bytes inside a `List[UInt8]` at a typed API, which would remove the need for the cast in byte-backed containers.

### Why is the standard library's parallelize banned?

**Decision.** Parallel work runs on a `ParallelDispatch`, never on `parallelize[`.

**Because.** `parallelize` fans out onto the standard library's own thread pool, a second pool of workers that the runtime's topology-aware scheduler cannot see, pin or limit. Its `@parameter` closures also capture their environment through wildcard origins, the class of bug the previous section describes.

**Alternatives weighed.**

- Allow `parallelize` with per-site review: each use still adds the second pool, which the runtime's scheduler cannot see.

**Revisit if.** The standard library lets a caller supply the worker pool.

## What must always hold?

None of these is checked by the build in this repository today; each is held by review.

- **No `unsafe_from_address=`.**
- **No partial move via a pointer.**
- **No new declaration of the reserved libc `read` or `open`.**
- **No `parallelize[`.** Today the spelling appears in `src/` only in comments.
- **No public function takes or returns a pointer.**
- **No wildcard origin outside a module's internals.** See the limits.
- **Every `UnsafePointer` carries a `# SAFETY:` comment.**

The spelling rules in the table above are different: the compiler refuses the old spelling, so every build checks them.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_core/collections/byte_view.mojo`, `slab.mojo` | the view and slab types that keep pointers private | `ByteView`, `Slab` |
| `src/komira_core/runtime_traits/parallel_dispatch.mojo`, `fork_join_shared.mojo` | the parallel dispatch contract | `ParallelDispatch`, `NoDispatch`, `fork_join_shared` |
| `src/komira_core/io/mmap_region.mojo`, `src/komira_core/native/komira_core_posix.c` | an FFI boundary through a C shim that resolves platform constants in C | `open_readonly`, `komira_open_ro` |
| `tools/build/toolchains/BUCK` | the compiler pin | the `mojo-compiler` 1.0.0 packages |

Entry points:

- **Public API:** none; the rules apply to every Mojo file.
- **Execution starts at:** nothing runs; the compiler enforces the spellings at every build.

## How is it tested?

The spelling rules are tested by compiling the tree: `./buck2 build //...` fails on an old spelling. Nothing tests the other rules.

## What are its limits and open questions?

- **Limit: the pointer and origin rules have no check.** No lint in this repository looks for a public pointer, a wildcard origin, `unsafe_from_address=`, a partial move or `parallelize[`, so a new violation leaves the build green.
- **Limit: wildcard origins are common.** 40 non-test files under `src/` name `MutAnyOrigin`, `ImmutAnyOrigin` or `MutExternalOrigin`, 23 name `MutUntrackedOrigin`, and `Slab.get_mut_interior` returns `ref [MutUntrackedOrigin] Self.T`. The ban describes new code, not the tree.
- **Limit: two Mojo 1.1 miscompiles have no check.** On Mojo 1.1 a program crashes when a `ref name = ...` alias is read inside a nested `@parameter` closure (the closure reads a dead slot), and copies zeros when `unsafe_memcpy`'s `src=` is a pointer to a local cast to an untracked origin. Pass the referent as a closure argument, and write the bytes explicitly.
- **Open question: should the rules become build actions, and should a pointer rule be a type check?** A line-pattern lint run as part of each library's build would turn the rules above into checks. Patterns over source text still miss a pointer type reached through an alias or a type parameter; a checker with type information would not. What would decide the second half is whether Mojo exposes such a checker.
