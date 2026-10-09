/*
 * The CPython C API the Python UDF runtime calls, as function pointers
 * resolved with dlsym from the libpython it loads (pyapi.c).
 *
 * The runtime library links no libpython: a host loads it with RTLD_NOW, so
 * a direct reference to a Py* symbol would fail that load unless libpython
 * were already in the process. Python.h is included for its types, struct
 * layouts and constants only (PyConfig, PyInterpreterConfig, Py_buffer,
 * PyMethodDef). No function or object of Python.h is referenced directly:
 * every call goes through `struct pyapi`, whose member types are taken from
 * the header's own declarations, so a signature mismatch is a compile error.
 * Macros that expand to a symbol reference (Py_None, Py_INCREF, Py_DECREF)
 * are not used; Py_IncRef, Py_DecRef and the `none` member stand in for them.
 */
#ifndef KOMIRA_UDF_SPIKE_PYAPI_H
#define KOMIRA_UDF_SPIKE_PYAPI_H

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stddef.h>

#define PYAPI_FN(name) __typeof__(&name) name

struct pyapi {
  void* lib;
  PyObject* none; /* &_Py_NoneStruct */
  /* life cycle */
  PYAPI_FN(Py_GetVersion);
  PYAPI_FN(PyConfig_InitIsolatedConfig);
  PYAPI_FN(PyConfig_SetBytesString);
  PYAPI_FN(PyConfig_Clear);
  PYAPI_FN(Py_InitializeFromConfig);
  PYAPI_FN(PyStatus_Exception);
  PYAPI_FN(Py_FinalizeEx);
  PYAPI_FN(Py_NewInterpreterFromConfig);
  PYAPI_FN(Py_EndInterpreter);
  PYAPI_FN(PyInterpreterState_Main);
  PYAPI_FN(PyThreadState_New);
  PYAPI_FN(PyThreadState_Clear);
  PYAPI_FN(PyThreadState_DeleteCurrent);
  PYAPI_FN(PyEval_SaveThread);
  PYAPI_FN(PyEval_RestoreThread);
  /* objects */
  PYAPI_FN(Py_IncRef);
  PYAPI_FN(Py_DecRef);
  PYAPI_FN(PyImport_ImportModule);
  PYAPI_FN(PyObject_GetAttrString);
  PYAPI_FN(PyObject_CallObject);
  PYAPI_FN(PyObject_CallMethodObjArgs);
  PYAPI_FN(PyObject_Str);
  PYAPI_FN(PyObject_GetBuffer);
  PYAPI_FN(PyBuffer_Release);
  PYAPI_FN(PyTuple_New);
  PYAPI_FN(PyTuple_SetItem);
  PYAPI_FN(PyTuple_GetItem);
  PYAPI_FN(PyTuple_Size);
  PYAPI_FN(PyList_New);
  PYAPI_FN(PyList_SetItem);
  PYAPI_FN(PyLong_FromLongLong);
  PYAPI_FN(PyLong_AsLongLong);
  PYAPI_FN(PyLong_FromVoidPtr);
  PYAPI_FN(PyLong_AsVoidPtr);
  PYAPI_FN(PyUnicode_FromString);
  PYAPI_FN(PyUnicode_DecodeFSDefault);
  PYAPI_FN(PyUnicode_AsUTF8);
  PYAPI_FN(PyMemoryView_FromMemory);
  PYAPI_FN(PyMemoryView_FromObject);
  PYAPI_FN(PyBuffer_FillInfo);
  PYAPI_FN(PyType_FromSpec);
  PYAPI_FN(PyCMethod_New);
  PYAPI_FN(PyErr_Occurred);
  PYAPI_FN(PyErr_GetRaisedException);
  PYAPI_FN(PyErr_Clear);
};

/* Loads libpython from `path` (RTLD_NOW | RTLD_GLOBAL, so extension modules
 * find the Py* symbols; design section 5.3) and fills `api`. Never closed.
 * Returns 1, or 0 with a one-line reason in `why`. */
int pyapi_load(struct pyapi* api, const char* path, char* why, size_t why_len);

#endif
