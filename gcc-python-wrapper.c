/*
   Copyright 2012 David Malcolm <dmalcolm@redhat.com>
   Copyright 2012 Red Hat, Inc.

   This is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see
   <http://www.gnu.org/licenses/>.
*/

/*
  Low-level wrapper support, with integration with GCC's garbage
  collector (aka "GGC")

  High-level overview
  ===================

  We keep track of all "live" wrapper objects, and each one knows how
  to mark the object it wraps; we register a hook into GCC"s GC so that
  when it starts marking, we iterate through all our live wrapper objects,
  marking the underlying GCC objects.


  Implementation details
  ======================

  All of our wrapper types are subclasses of PyGccWrapper, which adds
  a doubly-linked list to the top of the objects, so that we can track
  all live wrapper objects.  This list is updated via their PyTypeObject's
  tp_alloc and tp_dealloc.

  Each has a PyTypeObject that's actually a PyGccWrapperTypeObject, which adds
  a "wrtp_mark" hook to a PyTypeObject, so that it can participate in
  GCC's garbage collector.  It actually has to add it to PyHeapTypeObject,
  given that that's the (larger) in-memory layout of a user-defined type.

  In order to correctly inherit this wrtp_mark slot, we need to override the
  creation of any user-defined subclases of these PyTypeObjects, adding the
  "inherit the wrtp_mark callback" logic.  We do this by setting the ob_type
  of our PyGccWrapperTypeObject to be PyGccWrapperMeta_TypeObj, which supplies
  a custom tp_new hook: analogous to setting a __metaclass__:

     http://docs.python.org/reference/datamodel.html#customizing-class-creation

  Thus, given e.g.

      class MyPass(gcc.GimplePass):
           ...etc...
      p = MyPass('mypass')

  p is a PyGccPass
     ob_type == address on heap of user-defined type ("MyPass")

  "MyPass" is this heap-allocated PyGccWrapperTypeObject:
     ob_type == &PyGccWrapperMetaType
     tp_base == &PyGccGimplePassType (the parent class: "gcc.GimplePass")
     wrtp_mark == PyGcc_WrtpMarkForPyGccPass (inherited from tp_base via
                  PyGccWrapperMetaType.tp_new)

  PyGccGimplePassType is a statically-allocated PyGccWrapperTypeObject (in
  autogenerated-pass.c):
     ob_type == &PyGccWrapperMetaType
     tp_base == &PyGccPass_TypeObj (the parent class: "gcc.Pass")
     wrtp_mark == PyGcc_WrtpMarkForPyGccPass ("manually" set up by
                  generate-pass-c.py)

  PyGccPass_TypeObj is a statically-allocated PyGccWrapperTypeObject (in
  autogenerated-pass.c):
     ob_type == &PyGccWrapperMetaType
     tp_base == NULL, but becomes &PyBaseObject_Type aka "object"
     wrtp_mark == PyGcc_WrtpMarkForPyGccPass ("manually" set up by
                  generate-pass-c.py)

  PyGccWrapperMetaType is the statically-allocated metaclass for the above
  type objects ("gcc.WrapperMeta")

  (as it happens, gcc.Pass wraps an object that doesn't participate in the
  GCC garbage collector, so this is somewhat redundant.  However, it should
  matter when creating user-defined subclasses of types that *do* wrap a
  GC-managed object)

*/

#include <Python.h>
#include "gcc-python.h"
#include "gcc-python-wrappers.h"
#include "gcc-python-compat.h"

static void
force_gcc_gc(void);

/* Debugging, for use by selftest routine */
static int debug_PyGcc_wrapper = 0;

/*
  This is the overriden tp_new in our metatype: when we create new subtypes,
  it copies up our added slots:
*/
static PyObject*
PyGcc_wrapper_meta_tp_new(PyTypeObject *type, PyObject *args, PyObject *kwds)
{
    PyGccWrapperTypeObject* new_type;
    PyGccWrapperTypeObject* base_type;

    /* Use PyType_Type's tp_new to do most of the work: */
    new_type = (PyGccWrapperTypeObject*)PyType_Type.tp_new(type, args, kwds);
    if (!new_type) {
        return NULL;
    }

    /* Verify that the metaclass is sane, and that the created type object
       will thus be large enough for our extra information: */
    assert(Py_TYPE(new_type)->tp_basicsize >= (int)sizeof(PyGccWrapperTypeObject));

    base_type = (PyGccWrapperTypeObject*)((PyTypeObject*)new_type)->tp_base;
    assert(base_type);

    /* Inherit wrtp_mark: */
    assert(base_type->wrtp_mark);
    new_type->wrtp_mark = base_type->wrtp_mark;

    return (PyObject*)new_type;
}

PyTypeObject PyGccWrapperMeta_TypeObj  = {
    PyVarObject_HEAD_INIT(&PyType_Type, 0)
    "gcc.WrapperMeta", /*tp_name*/
    sizeof(PyGccWrapperTypeObject), /*tp_basicsize*/
    0, /*tp_itemsize*/
    NULL, /* tp_dealloc */
#if PY_VERSION_HEX >= 0x03080000
    0, /*tp_vectorcall_offset*/
#else
    NULL, /* tp_print */
#endif
    NULL, /* tp_getattr */
    NULL, /* tp_setattr */
#if PY_MAJOR_VERSION < 3
    0, /*tp_compare*/
#else
    0, /*reserved*/
#endif
    NULL, /* tp_repr */
    NULL, /* tp_as_number */
    NULL, /* tp_as_sequence */
    NULL, /* tp_as_mapping */
    NULL, /* tp_hash */
    NULL, /* tp_call */
    NULL, /* tp_str */
    NULL, /* tp_getattro */
    NULL, /* tp_setattro */
    NULL, /* tp_as_buffer */
    Py_TPFLAGS_DEFAULT, /* tp_flags */
    0, /*tp_doc*/
    NULL, /* tp_traverse */
    NULL, /* tp_clear */
    NULL, /* tp_richcompare */
    0, /* tp_weaklistoffset */
    NULL, /* tp_iter */
    NULL, /* tp_iternext */
    NULL, /* tp_methods */
    NULL, /* tp_members */
    NULL, /* tp_getset */
    &PyType_Type, /* tp_base */
    NULL, /* tp_dict */
    NULL, /* tp_descr_get */
    NULL, /* tp_descr_set */
    0, /* tp_dictoffset */
    NULL, /* tp_init */
    NULL, /* tp_alloc */
    PyGcc_wrapper_meta_tp_new, /* tp_new */
    NULL, /* tp_free */
    NULL, /* tp_is_gc */
    NULL, /* tp_bases */
    NULL, /* tp_mro */
    NULL, /* tp_cache */
    NULL, /* tp_subclasses */
    NULL, /* tp_weaklist */
    NULL, /* tp_del */
#if PY_VERSION_HEX >= 0x02060000
    0, /*tp_version_tag*/
#endif
};

/* Maintain a circular linked list of PyGccWrapper instances: */
static struct PyGccWrapper sentinel = {
    PyObject_HEAD_INIT(NULL)
    &sentinel,
    &sentinel,
};

PyGccWrapper *
_PyGccWrapper_New(PyGccWrapperTypeObject *typeobj)
{
    PyGccWrapper *obj;
    assert(typeobj);

    obj = PyObject_New(PyGccWrapper,
                       (PyTypeObject*)typeobj);
    if (!obj) {
        return NULL;
    }

    /* Add to list of live PyGccWrapper objects: */
    PyGccWrapper_Track(obj);

    return obj;
}

extern void
PyGccWrapper_Track(struct PyGccWrapper *obj)
{
    assert(obj);
    assert(sentinel.wr_next);
    assert(sentinel.wr_prev);
    /* obj is uninitialized, apart from ob_type and ob_refcnt */

    if (debug_PyGcc_wrapper) {
        printf("  PyGccWrapper_Track: %s\n",
               Py_TYPE(obj)->tp_name);
    }

    /*
      obj's type must use correct delloc, so that obj removes itself from the
      list.  obj->ob_type->tp_dealloc should be either
      PyGccWrapper_Dealloc or subtype_dealloc
     */

    /* Add to end of list, immediately before sentinel: */
    assert(sentinel.wr_prev->wr_next == &sentinel);
    sentinel.wr_prev->wr_next = obj;
    obj->wr_prev = sentinel.wr_prev;
    obj->wr_next = &sentinel;
    sentinel.wr_prev = obj;

    assert(obj->wr_prev);
    assert(obj->wr_next);
}

void
PyGcc_wrapper_untrack(struct PyGccWrapper *obj)
{
    if (debug_PyGcc_wrapper) {
        printf("    PyGcc_wrapper_untrack: %s\n", Py_TYPE(obj)->tp_name);
    }

    assert(obj);
    assert(Py_REFCNT(obj) == 0);

    /*
      Remove from the linked list if it's within it

      (If the object constructor fails, then we have only a
      partially-constructed object, which might not have been
      added to the linked list yet)
    */
    if (obj->wr_prev) {
        assert(sentinel.wr_next);
        assert(sentinel.wr_prev);
        assert(obj->wr_next);

        /* Remove from linked list: */
        obj->wr_prev->wr_next = obj->wr_next;
        obj->wr_next->wr_prev = obj->wr_prev;
        obj->wr_prev = NULL;
        obj->wr_next = NULL;
    }
}

void
PyGccWrapper_Dealloc(PyObject *obj)
{
    assert(obj);
    assert(Py_REFCNT(obj) == 0);
    if (debug_PyGcc_wrapper) {
        printf("  PyGccWrapper_Dealloc: %s\n",
               Py_TYPE(obj)->tp_name);
    }
    PyGcc_wrapper_untrack((struct PyGccWrapper*)obj);
    Py_TYPE(obj)->tp_free(obj);
}

static void
my_walker(void *arg ATTRIBUTE_UNUSED)
{
    /*
      Callback for use by GCC's garbage collector when marking

      Walk all the PyGccWrapper objects here and if they reference
      GCC GC objects, mark the underlying GCC objects so that they
      don't get swept
    */
    struct PyGccWrapper *iter;

    if (debug_PyGcc_wrapper) {
        printf("  walking the live PyGccWrapper objects\n");
    }
    for (iter = sentinel.wr_next; iter != &sentinel; iter = iter->wr_next) {
        wrtp_marker wrtp_mark;
        if (debug_PyGcc_wrapper) {
            printf("    marking inner object for: ");
            PyObject_Print((PyObject*)iter, stdout, 0);
            printf("\n");
        }
        wrtp_mark = ((PyGccWrapperTypeObject*)Py_TYPE(iter))->wrtp_mark;
        assert(wrtp_mark);
        wrtp_mark(iter);
    }
    if (debug_PyGcc_wrapper) {
        printf("  finished walking the live PyGccWrapper objects\n");
    }
}

static struct ggc_root_tab myroottab[] = {
    { (char*)"", 1, 1, my_walker, NULL },
    { NULL, }
};

void
PyGcc_wrapper_init(void)
{
    /* Register our GC root-walking callback: */
    ggc_register_root_tab(myroottab);

    PyType_Ready(&PyGccWrapperMeta_TypeObj);
}

static void
force_gcc_gc(void)
{
#if (GCC_VERSION < 12000)
    bool stored = ggc_force_collect;

    ggc_force_collect = true;
    ggc_collect();
    ggc_force_collect = stored;
#else
    ggc_collect(GGC_COLLECT_FORCE);
#endif
}

PyObject *
PyGcc__force_garbage_collection(PyObject *self, PyObject *args)
{
    force_gcc_gc();
    Py_RETURN_NONE;
}

#define MY_ASSERT(condition) \
    if (!(condition)) { \
         PyErr_SetString(PyExc_AssertionError, #condition); \
         return NULL; \
    }

PyObject *
PyGcc__gc_selftest(PyObject *self, PyObject *args)
{
    tree tree_intcst;
    PyObject *wrapper_intcst;

    tree tree_str;
    PyObject *wrapper_str;

    printf("gcc._gc_selftest() starting\n");

    /* Enable verbose logging: */
    debug_PyGcc_wrapper = 1;

    /*
      Approach: construct various GCC objects here, unreferenced by anything.
      Wrap them in Python objects, then force the GCC GC, then verify that the
      underlying objects were marked, and weren't collected.

      See http://gcc.gnu.org/onlinedocs/gccint/Type-Information.html for some
      notes on GCC's garbage collector.
    */

    printf("creating test GCC objects\n");

    /* We're called from PLUGIN_FINISH, so integer_types[] should be ready: */
    tree_intcst = build_int_cst(integer_types[itk_int], 42);
    wrapper_intcst = PyGccTree_NewUnique(gcc_private_make_tree(tree_intcst));
    MY_ASSERT(wrapper_intcst);

    #define MY_TEST_STRING "I am only referenced via a python wrapper"
    tree_str = build_string(strlen(MY_TEST_STRING), MY_TEST_STRING);

    /* We should now have a newly-allocated tree node; it should not
       have been marked yet by the GC: */
    MY_ASSERT(tree_str);
    //MY_ASSERT(!ggc_marked_p(str)); // this fails, why? why is it being marked?

    /* Wrap it with a Python object: */
    wrapper_str = PyGccTree_NewUnique(gcc_private_make_tree(tree_str));
    MY_ASSERT(wrapper_str);

    /* Force a garbage collection: */
    printf("forcing a garbage collection:\n");
    force_gcc_gc();
    printf("completed the forced garbage collection\n");

    /*
      Verify that the various wrapped objects were marked (via the Python
      wrapper).
      If it was not marked, then we're accessing freed memory,
      and this will likely fail with an Internal Compiler Error
     */
    printf("verifying that the underlying GCC objects were marked\n");
    MY_ASSERT(ggc_marked_p(tree_intcst));
    MY_ASSERT(ggc_marked_p(tree_str));
    printf("all of the underlying GCC objects were indeed marked\n");

    /* Clean up the wrapper objects: */
    printf("invoking DECREF on Python wrapper objects\n");
    Py_DECREF(wrapper_intcst);
    Py_DECREF(wrapper_str);

    /* FIXME: need to do this for all of our types (base classes, at least) */

    printf("gcc._gc_selftest() complete\n");

    /* Turn off verbose logging: */
    debug_PyGcc_wrapper = 0;

    Py_RETURN_NONE;
}

/*
  PEP-7
Local variables:
c-basic-offset: 4
indent-tabs-mode: nil
End:
*/
