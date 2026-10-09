/*
 * Resolves the CPython C API of rowpy.h from a libpython loaded at run time.
 * FFI-BOUNDARY: the libpython handle is opened once and never closed (an
 * interpreter's extension modules and threads outlive any scope here); the
 * symbols are the library's, valid while it is loaded.
 */
#include "rowpy.h" /* first: Python.h sets the feature macros (_GNU_SOURCE) */

#include <dlfcn.h>
#include <stdio.h>

#define RESOLVE(name)                                                        \
  do {                                                                       \
    api->name = (__typeof__(api->name))dlsym(api->lib, #name);               \
    if (api->name == NULL) {                                                 \
      snprintf(why, why_len, "libpython %s has no symbol %s", path, #name); \
      return 0;                                                              \
    }                                                                        \
  } while (0)

int rowpy_load(struct rowpy* api, const char* path, char* why, size_t why_len) {
  api->lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (api->lib == NULL) {
    const char* e = dlerror();
    snprintf(why, why_len, "cannot load libpython: %s", e ? e : path);
    return 0;
  }
  api->none = (PyObject*)dlsym(api->lib, "_Py_NoneStruct");
  if (api->none == NULL) {
    snprintf(why, why_len, "libpython %s has no symbol _Py_NoneStruct", path);
    return 0;
  }
  RESOLVE(Py_GetVersion);
  RESOLVE(PyConfig_InitIsolatedConfig);
  RESOLVE(PyConfig_SetBytesString);
  RESOLVE(PyConfig_Clear);
  RESOLVE(Py_InitializeFromConfig);
  RESOLVE(PyStatus_Exception);
  RESOLVE(Py_FinalizeEx);
  RESOLVE(Py_NewInterpreterFromConfig);
  RESOLVE(Py_EndInterpreter);
  RESOLVE(PyInterpreterState_Main);
  RESOLVE(PyThreadState_New);
  RESOLVE(PyThreadState_Clear);
  RESOLVE(PyThreadState_DeleteCurrent);
  RESOLVE(PyEval_SaveThread);
  RESOLVE(PyEval_RestoreThread);
  RESOLVE(Py_IncRef);
  RESOLVE(Py_DecRef);
  RESOLVE(PyImport_ImportModule);
  RESOLVE(PyObject_GetAttrString);
  RESOLVE(PyObject_CallObject);
  RESOLVE(PyObject_CallMethodObjArgs);
  RESOLVE(PyObject_Str);
  RESOLVE(PyTuple_New);
  RESOLVE(PyTuple_SetItem);
  RESOLVE(PyTuple_GetItem);
  RESOLVE(PyList_New);
  RESOLVE(PyList_SetItem);
  RESOLVE(PyLong_FromLongLong);
  RESOLVE(PyLong_AsLongLong);
  RESOLVE(PyUnicode_FromString);
  RESOLVE(PyUnicode_DecodeFSDefault);
  RESOLVE(PyUnicode_AsUTF8);
  RESOLVE(PyMemoryView_FromMemory);
  RESOLVE(PyMemoryView_FromObject);
  RESOLVE(PyBuffer_FillInfo);
  RESOLVE(PyType_FromSpec);
  RESOLVE(PyCMethod_New);
  RESOLVE(PyErr_Occurred);
  RESOLVE(PyErr_GetRaisedException);
  RESOLVE(PyErr_Clear);
  return 1;
}
