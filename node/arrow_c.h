// The Arrow C Data Interface and C Stream Interface structs, as the Arrow
// specification defines them (format/CDataInterface.html,
// format/CStreamInterface.html), and the type tag of an Arrow C stream
// capsule: an N-API external whose data is a `struct ArrowArrayStream *`.
//
// A capsule is how one addon hands another a stream it owns, as a PyCapsule
// named "arrow_array_stream" does in Python. `importArrowStream` refuses an
// external without this tag. The addon that made the capsule owns the struct;
// the importer moves the stream out of it (copies the struct and sets the
// capsule's `release` to NULL, which the C Stream Interface allows), so the
// maker's finalizer releases the stream only if nobody imported it.
#ifndef KOMIRA_NODE_ARROW_C_H
#define KOMIRA_NODE_ARROW_C_H

#include <stdint.h>

#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE

#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

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

#endif  // ARROW_C_DATA_INTERFACE

#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *out);
  int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *out);
  const char *(*get_last_error)(struct ArrowArrayStream *);
  void (*release)(struct ArrowArrayStream *);
  void *private_data;
};

#endif  // ARROW_C_STREAM_INTERFACE

// The napi_type_tag of an Arrow C stream capsule ("komira.arrow.stream").
#define KOMIRA_ARROW_STREAM_TAG_LOWER 0x6b6f6d6972612e61ULL
#define KOMIRA_ARROW_STREAM_TAG_UPPER 0x72726f772e737472ULL

#endif  // KOMIRA_NODE_ARROW_C_H
