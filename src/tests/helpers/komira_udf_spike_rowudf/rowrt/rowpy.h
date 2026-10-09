/*
 * The CPython C API the row runtime calls, as function pointers resolved
 * with dlsym from the libpython it loads (rowpy.c).
 *
 * The runtime library links no libpython: a host loads it with RTLD_NOW, so
 * a direct reference to a Py* symbol would fail that load unless libpython
 * were already in the process. Python.h is included for its types, struct
 * layouts and constants only. No function or object of Python.h is
 * referenced directly: every call goes through `struct rowpy`, whose member
 * types are taken from the header's own declarations, so a signature
 * mismatch is a compile error. Py_None, Py_INCREF and Py_DECREF expand to
 * symbol references and are not used; Py_IncRef, Py_DecRef and the `none`
 * member stand in for them.
 *
 * This is the subset of the komira-test/python runtime's table
 * (komira_udf_spike_python/pyrt/pyapi.h) the row runtime needs, under its
 * own names: that header is private to its package.
 */
#ifndef KOMIRA_UDF_SPIKE_ROWPY_H
#define KOMIRA_UDF_SPIKE_ROWPY_H

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stddef.h>

#define ROWPY_FN(name) __typeof__(&name) name

struct rowpy {
  void* lib;
  PyObject* none; /* &_Py_NoneStruct */
  /* life cycle */
  ROWPY_FN(Py_GetVersion);
  ROWPY_FN(PyConfig_InitIsolatedConfig);
  ROWPY_FN(PyConfig_SetBytesString);
  ROWPY_FN(PyConfig_Clear);
  ROWPY_FN(Py_InitializeFromConfig);
  ROWPY_FN(PyStatus_Exception);
  ROWPY_FN(Py_FinalizeEx);
  ROWPY_FN(Py_NewInterpreterFromConfig);
  ROWPY_FN(Py_EndInterpreter);
  ROWPY_FN(PyInterpreterState_Main);
  ROWPY_FN(PyThreadState_New);
  ROWPY_FN(PyThreadState_Clear);
  ROWPY_FN(PyThreadState_DeleteCurrent);
  ROWPY_FN(PyEval_SaveThread);
  ROWPY_FN(PyEval_RestoreThread);
  /* objects */
  ROWPY_FN(Py_IncRef);
  ROWPY_FN(Py_DecRef);
  ROWPY_FN(PyImport_ImportModule);
  ROWPY_FN(PyObject_GetAttrString);
  ROWPY_FN(PyObject_CallObject);
  ROWPY_FN(PyObject_CallMethodObjArgs);
  ROWPY_FN(PyObject_Str);
  ROWPY_FN(PyTuple_New);
  ROWPY_FN(PyTuple_SetItem);
  ROWPY_FN(PyTuple_GetItem);
  ROWPY_FN(PyList_New);
  ROWPY_FN(PyList_SetItem);
  ROWPY_FN(PyLong_FromLongLong);
  ROWPY_FN(PyLong_AsLongLong);
  ROWPY_FN(PyUnicode_FromString);
  ROWPY_FN(PyUnicode_DecodeFSDefault);
  ROWPY_FN(PyUnicode_AsUTF8);
  ROWPY_FN(PyMemoryView_FromMemory);
  ROWPY_FN(PyMemoryView_FromObject);
  ROWPY_FN(PyBuffer_FillInfo);
  ROWPY_FN(PyType_FromSpec);
  ROWPY_FN(PyCMethod_New);
  ROWPY_FN(PyErr_Occurred);
  ROWPY_FN(PyErr_GetRaisedException);
  ROWPY_FN(PyErr_Clear);
};

/* Loads libpython from `path` (RTLD_NOW | RTLD_GLOBAL, so extension modules
 * find the Py* symbols) and fills `api`. Never closed. Returns 1, or 0 with
 * a one-line reason in `why`. */
int rowpy_load(struct rowpy* api, const char* path, char* why, size_t why_len);

#endif
