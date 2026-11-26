//! The checks a new import name must pass (mopm's design of owner namespaces, sections 1, 1.1
//! and 12.2): the name grammar, Mojo's keywords and builtins, mopm's reserved names, and every
//! name of the Mojo 1.0.0 standard library at any depth.

use std::fmt;

/// Mojo's keywords, as mopm's client refuses them for a package name (`src/core/manifest.zig`,
/// `keywords`), and `match` and `case`, which Mojo 1.2.0 reserves.
pub const KEYWORDS: &[&str] = &[
    "alias", "and", "as", "assert", "async", "await", "borrowed", "break", "class", "comptime",
    "continue", "def", "deinit", "del", "elif", "else", "except", "finally", "fn", "for", "from",
    "global", "if", "import", "in", "inout", "is", "lambda", "let", "mut", "nonlocal", "not", "or",
    "out", "owned", "pass", "raise", "raises", "read", "ref", "return", "self", "struct", "trait",
    "try", "var", "while", "with", "yield", "match", "case",
];

/// The Mojo builtins a package of that name would shadow (mopm's `src/core/manifest.zig`,
/// `builtins`).
pub const BUILTINS: &[&str] = &[
    "abs",
    "all",
    "any",
    "bool",
    "chr",
    "divmod",
    "enumerate",
    "float",
    "hash",
    "input",
    "int",
    "isinstance",
    "iter",
    "len",
    "list",
    "max",
    "min",
    "next",
    "ord",
    "pow",
    "print",
    "range",
    "repr",
    "reversed",
    "round",
    "sorted",
    "str",
    "sum",
    "type",
    "zip",
];

/// The names mopm's registry reserves (`RESERVED_NAMES` of its claim handler).
pub const RESERVED: &[&str] = &["mopm", "mojo", "max", "modular", "std", "stdlib"];

/// Every directory and file name (without `.mojo`) under `mojo/stdlib/std/` of Mojo 1.0.0, those
/// starting with `_` left out: 173 names. Read from the 251 `.mojo` paths of the tag `mojo/v1.0.0`
/// of modular/modular, which are the source paths the `mojo-compiler` 1.0.0 package records
/// in its `lib/mojo/std.mojoc` (mopm's design of owner namespaces, section 1.1). Sorted as bytes.
pub const STD_NAMES: &[&str] = &[
    "address_space",
    "algorithm",
    "alloc",
    "anytype",
    "arc_pointer",
    "arg",
    "array",
    "asyncrt",
    "atomic",
    "backend",
    "base64",
    "bencher",
    "benchmark",
    "binary_heap",
    "bindings",
    "bit",
    "bitset",
    "bool",
    "breakpoint",
    "builtin",
    "builtin_slice",
    "check_bounds",
    "codepoint",
    "collections",
    "comparable",
    "compile",
    "compiler",
    "complex",
    "constants",
    "constrained",
    "conversions",
    "coord",
    "copyable",
    "coroutine",
    "counter",
    "cpu",
    "cstring",
    "cuda",
    "cuda_plugin",
    "debug",
    "debug_assert",
    "defines",
    "deinitable",
    "deque",
    "device_passable",
    "dict",
    "documentation",
    "dtype",
    "env",
    "error",
    "fast",
    "fast_div",
    "ffi",
    "file",
    "file_descriptor",
    "float_literal",
    "floatable",
    "format",
    "format_int",
    "fstat",
    "function",
    "functional",
    "globals",
    "gpu",
    "hash",
    "hasher",
    "hashlib",
    "hip",
    "hip_plugin",
    "host",
    "id",
    "identifiable",
    "index",
    "info",
    "int",
    "int_literal",
    "interval",
    "intrinsics",
    "io",
    "iter",
    "iterators",
    "itertools",
    "len",
    "linked_list",
    "list",
    "list_strategy",
    "location",
    "lock",
    "logger",
    "map",
    "mask",
    "math",
    "memory",
    "metal",
    "metal_plugin",
    "movable",
    "none",
    "numerics",
    "numpy",
    "optional",
    "origin",
    "os",
    "owned_pointer",
    "parsing_floats",
    "parsing_integers",
    "path",
    "pathlib",
    "pathlike",
    "philox",
    "pointer",
    "polynomial",
    "prelude",
    "primitives",
    "process",
    "profiler",
    "prop",
    "pwd",
    "python",
    "python_object",
    "quick_bench",
    "random",
    "range",
    "rebind",
    "reflect",
    "reflection",
    "repr",
    "reversed",
    "runner",
    "runtime",
    "selector",
    "set",
    "simd",
    "simd_length",
    "simd_strategy",
    "sort",
    "span",
    "stack_allocation",
    "stat",
    "static_tuple",
    "strategy",
    "string",
    "string_literal",
    "string_span",
    "string_strategy",
    "subprocess",
    "suite",
    "swap",
    "sys",
    "tempfile",
    "terminate",
    "testing",
    "tile",
    "time",
    "traits",
    "tstring",
    "tuple",
    "type_aliases",
    "type_dict",
    "type_functions",
    "type_info",
    "unsafe",
    "unsafe_maybe_uninit",
    "unsafe_pointer",
    "unsafe_union",
    "unswitch",
    "utils",
    "uutils",
    "value",
    "variadics",
    "variant",
    "vectorize",
    "warp",
    "write",
];

/// Why a name cannot be a new import name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameProblem {
    /// Not `^[a-z][a-z0-9_]{1,63}$`.
    Grammar,
    /// A Mojo keyword.
    Keyword,
    /// A Mojo builtin.
    Builtin,
    /// One of mopm's reserved names.
    Reserved,
    /// A directory or file name of the Mojo standard library.
    StdName,
}

impl fmt::Display for NameProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            NameProblem::Grammar => "is not a package name (^[a-z][a-z0-9_]{1,63}$)",
            NameProblem::Keyword => "is a Mojo keyword",
            NameProblem::Builtin => "is a Mojo builtin",
            NameProblem::Reserved => "is reserved by mopm",
            NameProblem::StdName => "is a name in the Mojo standard library",
        })
    }
}

/// True when `name` is `^[a-z][a-z0-9_]{1,63}$`.
pub fn grammar_ok(name: &str) -> bool {
    let bytes = name.as_bytes();
    (2..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

/// Why `name` cannot be a new import name, or `None` when it can.
pub fn name_problem(name: &str) -> Option<NameProblem> {
    if !grammar_ok(name) {
        Some(NameProblem::Grammar)
    } else if KEYWORDS.contains(&name) {
        Some(NameProblem::Keyword)
    } else if BUILTINS.contains(&name) {
        Some(NameProblem::Builtin)
    } else if RESERVED.contains(&name) {
        Some(NameProblem::Reserved)
    } else if STD_NAMES.contains(&name) {
        Some(NameProblem::StdName)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn std_names_are_the_173_sorted_names_of_mojo_1_0_0() {
        assert_eq!(STD_NAMES.len(), 173);
        assert!(STD_NAMES.windows(2).all(|w| w[0] < w[1]));
        // The 37 top-level modules of section 1.1 are all in the list.
        for module in [
            "algorithm",
            "atomic",
            "base64",
            "benchmark",
            "bit",
            "builtin",
            "collections",
            "compile",
            "complex",
            "documentation",
            "ffi",
            "format",
            "gpu",
            "hashlib",
            "io",
            "iter",
            "itertools",
            "logger",
            "math",
            "memory",
            "origin",
            "os",
            "pathlib",
            "prelude",
            "pwd",
            "python",
            "random",
            "reflection",
            "runtime",
            "stat",
            "subprocess",
            "sys",
            "tempfile",
            "testing",
            "time",
            "traits",
            "utils",
        ] {
            assert!(STD_NAMES.contains(&module), "{module}");
        }
    }

    #[test]
    fn grammar_accepts_two_to_64_lowercase_bytes_and_refuses_the_rest() {
        assert!(grammar_ok("ab"));
        assert!(grammar_ok("a1_"));
        assert!(grammar_ok(&"a".repeat(64)));
        assert!(!grammar_ok("a"));
        assert!(!grammar_ok(""));
        assert!(!grammar_ok(&"a".repeat(65)));
        assert!(!grammar_ok("1a"));
        assert!(!grammar_ok("_a"));
        assert!(!grammar_ok("aB"));
        assert!(!grammar_ok("a-b"));
        assert!(!grammar_ok("a.b"));
        assert!(!grammar_ok("aé"));
    }

    #[test]
    fn each_list_names_its_own_problem_and_a_free_name_has_none() {
        assert_eq!(name_problem("Json"), Some(NameProblem::Grammar));
        assert_eq!(name_problem("async"), Some(NameProblem::Keyword));
        assert_eq!(name_problem("match"), Some(NameProblem::Keyword));
        assert_eq!(name_problem("case"), Some(NameProblem::Keyword));
        assert_eq!(name_problem("hash"), Some(NameProblem::Builtin));
        assert_eq!(name_problem("mopm"), Some(NameProblem::Reserved));
        assert_eq!(name_problem("collections"), Some(NameProblem::StdName));
        assert_eq!(name_problem("host"), Some(NameProblem::StdName));
        assert_eq!(name_problem("simd"), Some(NameProblem::StdName));
        assert_eq!(name_problem("json"), None);
        assert_eq!(name_problem("containers"), None);
    }

    #[test]
    fn every_problem_reads_as_a_sentence_end() {
        let all = [
            (
                NameProblem::Grammar,
                "is not a package name (^[a-z][a-z0-9_]{1,63}$)",
            ),
            (NameProblem::Keyword, "is a Mojo keyword"),
            (NameProblem::Builtin, "is a Mojo builtin"),
            (NameProblem::Reserved, "is reserved by mopm"),
            (
                NameProblem::StdName,
                "is a name in the Mojo standard library",
            ),
        ];
        for (problem, text) in all {
            assert_eq!(problem.to_string(), text);
        }
    }
}
