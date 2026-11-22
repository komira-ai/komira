/*
 * wire.c: the framing of the wire (udfpy_wire.h), the komira_udf_error
 * helpers and the monotonic clock.
 *
 * Every send is one sendmsg with MSG_NOSIGNAL: a peer that died is an error
 * here, never a SIGPIPE in the engine.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>

#include "udfpy.h"

int64_t udfpy_mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

/* ---- errors ------------------------------------------------------------------ */

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->release = NULL;
}

static int writable(const komira_udf_error* e) {
  return e != NULL && e->struct_size >= sizeof(*e);
}

static void set_error(komira_udf_error* e, int32_t code, int64_t row, int64_t group, char* msg, char* trace) {
  if (!writable(e)) {
    free(msg);
    free(trace);
    return;
  }
  e->code = code;
  e->message = msg;
  e->user_trace = trace;
  e->row = row;
  e->group = group;
  e->release = free_error;
}

int32_t udfpy_fail(komira_udf_error* e, int32_t code, int64_t row, const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  set_error(e, code, row, -1, strdup(buf), NULL);
  return code;
}

void udfpy_error_move(komira_udf_error* to, komira_udf_error* from) {
  if (writable(to)) {
    to->code = from->code;
    to->message = from->message;
    to->user_trace = from->user_trace;
    to->row = from->row;
    to->group = from->group;
    to->release = free_error;
  } else if (from->release != NULL) {
    from->release(from);
  }
  from->release = NULL;
  from->message = NULL;
  from->user_trace = NULL;
}

static const char* const STATUS_NAMES[] = {
    "OK",
    "ERR_ABI",
    "ERR_DESCRIPTOR",
    "ERR_UNSUPPORTED",
    "ERR_CODE_DIGEST",
    "ERR_LOAD",
    "ERR_RAISED",
    "ERR_RETURN_TYPE",
    "ERR_LENGTH",
    "ERR_STATE_TOO_LARGE",
    "ERR_GROUP_TOO_LARGE",
    "ERR_CANCELLED",
    "ERR_DEADLINE",
    "ERR_OUT_OF_MEMORY",
    "ERR_INSTANCE_LOST",
    "ERR_INTERNAL",
    "ERR_FIELD_NOT_DECLARED",
    "ERR_WORKER_CRASHED",
    "ERR_HOST_CONTRACT",
    "ERR_KILLED",
    "ERR_READ_SET_MISMATCH",
    "ERR_BAD_OPTION",
};

const char* udfpy_status_name(int32_t code) {
  if (code < 0 || code >= (int32_t)(sizeof(STATUS_NAMES) / sizeof(STATUS_NAMES[0]))) return "ERR_UNKNOWN";
  return STATUS_NAMES[code];
}

/* ---- framing ------------------------------------------------------------------ */

int udfpy_send(int sock, uint32_t op, uint64_t request_id, uint32_t flags, uint64_t handle, int64_t deadline_left,
               int64_t call_id, const uint8_t* body, size_t body_len, const int* fds, int nfds) {
  if (nfds < 0 || nfds > 4) {
    errno = EINVAL;
    return -1;
  }
  udfpy_header h;
  memset(&h, 0, sizeof(h));
  h.magic = UDFPY_MAGIC;
  h.op = op;
  h.request_id = request_id;
  h.flags = flags | UDFPY_FLAG_INLINE;
  h.payload_len = UDFPY_HEAD_BYTES + body_len;
  uint8_t head[UDFPY_HEAD_BYTES];
  memset(head, 0, sizeof(head));
  memcpy(head, &handle, 8);
  memcpy(head + 8, &deadline_left, 8);
  memcpy(head + 16, &call_id, 8);
  struct iovec iov[3] = {{&h, sizeof(h)}, {head, sizeof(head)}, {(void*)body, body_len}};
  int n = body_len ? 3 : 2;
  struct iovec* v = iov;
  union {
    char buf[CMSG_SPACE(sizeof(int) * 4)];
    struct cmsghdr align;
  } ctl;
  int first = 1;
  while (n > 0) {
    struct msghdr m;
    memset(&m, 0, sizeof(m));
    m.msg_iov = v;
    m.msg_iovlen = (size_t)n;
    if (first && nfds > 0) {
      memset(&ctl, 0, sizeof(ctl));
      m.msg_control = ctl.buf;
      m.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
      struct cmsghdr* c = CMSG_FIRSTHDR(&m);
      c->cmsg_level = SOL_SOCKET;
      c->cmsg_type = SCM_RIGHTS;
      c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
      memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
    }
    ssize_t k = sendmsg(sock, &m, MSG_NOSIGNAL);
    if (k < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    first = 0;
    while (n > 0 && (size_t)k >= v->iov_len) {
      k -= (ssize_t)v->iov_len;
      v++;
      n--;
    }
    if (n > 0) {
      v->iov_base = (uint8_t*)v->iov_base + k;
      v->iov_len -= (size_t)k;
    }
  }
  return 0;
}

static int recv_all(int fd, void* dst, size_t n) {
  uint8_t* p = (uint8_t*)dst;
  while (n > 0) {
    ssize_t k = recv(fd, p, n, 0);
    if (k == 0) return -1;
    if (k < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += k;
    n -= (size_t)k;
  }
  return 0;
}

int udfpy_recv(int sock, udfpy_msg* m, const char** why) {
  memset(m, 0, sizeof(*m));
  udfpy_header h;
  if (recv_all(sock, &h, sizeof(h)) != 0) return -1;
  if (h.magic != UDFPY_MAGIC) {
    *why = "the magic number is wrong";
    return -2;
  }
  if (h.payload_len > UDFPY_MAX_PAYLOAD) {
    *why = "the payload is longer than the wire allows";
    return -2;
  }
  if (h.payload_len > 0 && (h.flags & UDFPY_FLAG_INLINE) == 0) {
    *why = "a payload without the INLINE flag";
    return -2;
  }
  if (h.payload_len > 0) {
    void* p = NULL;
    if (posix_memalign(&p, UDFPY_ALIGN, (size_t)h.payload_len) != 0) {
      *why = "no memory for the payload";
      return -2;
    }
    if (recv_all(sock, p, (size_t)h.payload_len) != 0) {
      free(p);
      return -1;
    }
    m->payload = (uint8_t*)p;
  }
  m->op = h.op;
  m->flags = h.flags;
  m->request_id = h.request_id;
  m->len = (size_t)h.payload_len;
  return 0;
}

void udfpy_msg_free(udfpy_msg* m) {
  free(m->payload);
  m->payload = NULL;
  m->len = 0;
}

static char* take_str(const uint8_t* p, size_t len, size_t* at, int* bad) {
  uint32_t n = 0;
  if (*at + 4 > len) {
    *bad = 1;
    return NULL;
  }
  memcpy(&n, p + *at, 4);
  *at += 4;
  if ((size_t)n > len - *at) {
    *bad = 1;
    return NULL;
  }
  char* s = (char*)malloc((size_t)n + 1);
  if (s == NULL) {
    *bad = 1;
    return NULL;
  }
  memcpy(s, p + *at, n);
  s[n] = 0;
  *at += n;
  return s;
}

int32_t udfpy_reply_status(const udfpy_msg* m, komira_udf_error* err) {
  if (m->op == UDFPY_OP_OK) return KOMIRA_UDF_OK;
  int32_t code = 0;
  int64_t row = -1, group = -1;
  if (m->len < 20) return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "a malformed ERROR reply (%zu bytes)", m->len);
  memcpy(&code, m->payload, 4);
  memcpy(&row, m->payload + 4, 8);
  memcpy(&group, m->payload + 12, 8);
  size_t at = 20;
  int bad = 0;
  char* msg = take_str(m->payload, m->len, &at, &bad);
  char* trace = bad ? NULL : take_str(m->payload, m->len, &at, &bad);
  if (bad) {
    free(msg);
    free(trace);
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "a malformed ERROR reply");
  }
  if (code <= 0 || code > KOMIRA_UDF_ERR_READ_SET_MISMATCH) code = KOMIRA_UDF_ERR_INTERNAL;
  if (trace != NULL && trace[0] == 0) {
    free(trace);
    trace = NULL;
  }
  set_error(err, code, row, group, msg, trace);
  return code;
}
