#   Copyright 2011-2013, 2017 David Malcolm <dmalcolm@redhat.com>
#   Copyright 2011-2013, 2017 Red Hat, Inc.
#
#   This is free software: you can redistribute it and/or modify it
#   under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see
#   <http://www.gnu.org/licenses/>.

ifneq ($(srcdir),)
VPATH = $(srcdir)
endif
xmldir = $(srcdir)./gcc-c-api/
pwd = $(shell pwd -P)

.PHONY: all clean debug dump_gimple plugin show-ssa tarball \
	test-suite testcpychecker testcpybuilder testdejagnu \
	man

PLUGIN_SOURCE_FILES= \
  gcc-python.c \
  gcc-python-attribute.c \
  gcc-python-callbacks.c \
  gcc-python-callgraph.c \
  gcc-python-cfg.c \
  gcc-python-closure.c \
  gcc-python-diagnostics.c \
  gcc-python-function.c \
  gcc-python-gimple.c \
  gcc-python-location.c \
  gcc-python-option.c \
  gcc-python-parameter.c \
  gcc-python-pass.c \
  gcc-python-pretty-printer.c \
  gcc-python-rtl.c \
  gcc-python-tree.c \
  gcc-python-variable.c \
  gcc-python-version.c \
  gcc-python-wrapper.c \

PLUGIN_GENERATED_SOURCE_FILES:= \
  autogenerated-callgraph.c \
  autogenerated-casts.c \
  autogenerated-cfg.c \
  autogenerated-option.c \
  autogenerated-function.c \
  autogenerated-gimple.c \
  autogenerated-location.c \
  autogenerated-parameter.c \
  autogenerated-pass.c \
  autogenerated-pretty-printer.c \
  autogenerated-rtl.c \
  autogenerated-tree.c \
  autogenerated-variable.c

PLUGIN_OBJECT_SOURCE_FILES:= $(patsubst %.c,%.o,$(PLUGIN_SOURCE_FILES))
PLUGIN_OBJECT_GENERATED_FILES:= $(patsubst %.c,%.o,$(PLUGIN_GENERATED_SOURCE_FILES))
PLUGIN_OBJECT_FILES:= $(PLUGIN_OBJECT_SOURCE_FILES) $(PLUGIN_OBJECT_GENERATED_FILES)
GCCPLUGINS_DIR:= $(shell $(CC) --print-file-name=plugin)

GENERATOR_DEPS=cpybuilder.py wrapperbuilder.py print-gcc-version

# The plugin supports both Python 2 and Python 3
#
# In theory we could have arbitrary combinations of python versions for each
# of:
#   - python version used when running scripts during the build (e.g. to
#     generate code)
#   - python version we compile and link the plugin against
#   - when running the plugin with the cpychecker script, the python version
#     that the code is being compiled against
#
# However, to keep things simple, let's assume for now that all of these are
# the same version: we're building the plugin using the same version of Python
# as we're linking against, and that the cpychecker will be testing that same
# version of Python
#
# By default, build against "python", using "python-config" to query for
# compilation options.  You can override this by passing other values for
# PYTHON and PYTHON_CONFIG when invoking "make" (or by simply hacking up this
# file): e.g.
#    make  PYTHON=python3  PYTHON_CONFIG=python3-config  all

# The python interpreter to use:
#PYTHON=python
# The python-config executable to use:
#PYTHON_CONFIG=python-config

PYTHON=python3
PYTHON_CONFIG=python3-config

#PYTHON=python-debug
#PYTHON_CONFIG=python-debug-config

#PYTHON=python3-debug
#PYTHON_CONFIG=python3.3dm-config

PYTHON_INCLUDES=$(shell $(PYTHON_CONFIG) --includes)
PYTHON_LIBS=$(shell $(PYTHON) -c 'import sys;print("-lpython%d.%d" % sys.version_info[:2])') $(shell $(PYTHON_CONFIG) --libs)

# Support having multiple named plugins
# e.g. "python2.7" "python3.2mu" "python 3.2dmu" etc:
PLUGIN_NAME := python
PLUGIN_DSO := $(PLUGIN_NAME).so
PLUGIN_DIR := $(PLUGIN_NAME)

# For now, gcc-c-api is part of this project
# (Eventually it will be moved to its own project)
LIBGCC_C_API_SO	:= gcc-c-api/libgcc-c-api.so

CPPFLAGS+= -I$(GCCPLUGINS_DIR)/include -I$(GCCPLUGINS_DIR)/include/c-family -I. $(PYTHON_INCLUDES)
# Allow user to pick optimization, choose whether warnings are fatal,
# and choose debugging information level.
CFLAGS?=-O2 -Werror -Wno-deprecated-declarations -g
# Force these settings
CFLAGS+= -fPIC -fno-strict-aliasing -Wall
LIBS+= $(PYTHON_LIBS)
ifneq "$(PLUGIN_PYTHONPATH)" ""
  CPPFLAGS+= -DPLUGIN_PYTHONPATH='"$(PLUGIN_PYTHONPATH)"'
endif

all: autogenerated-config.h testcpybuilder testdejagnu test-suite testcpychecker

# What still needs to be wrapped?
api-report:
	grep -nH -e "\.inner" gcc-*.c *.h generate-*.py

plugin: autogenerated-config.h $(PLUGIN_DSO)

# When running the plugin from a working copy, use LD_LIBARY_PATH=gcc-c-api
# so that the plugin can find its libgcc-c-api.so there
#
INVOCATION_ENV_VARS := PYTHONPATH=$(srcdir)./ CC_FOR_CPYCHECKER=$(CC) LD_LIBRARY_PATH=gcc-c-api:$(LD_LIBRARY_PATH) CC=$(CC)

# When installing, both the plugin and libgcc-c-api.so will be installed to
# $(GCCPLUGINS_DIR), so we give the plugin an RPATH of $(GCCPLUGINS_DIR)
# so that it finds the libgcc-c-api.so there (to support the case of having
# multiple GCCs installed)
#
$(PLUGIN_DSO): $(PLUGIN_OBJECT_FILES) $(LIBGCC_C_API_SO)
	$(CC) \
	    $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) \
	    -shared \
	    $(PLUGIN_OBJECT_FILES) \
	    -o $@ \
	    $(LIBS) \
	    -lgcc-c-api -Lgcc-c-api -Wl,-rpath=$(GCCPLUGINS_DIR)

$(pwd)/gcc-c-api:
	mkdir -p $@

$(LIBGCC_C_API_SO): $(pwd)/gcc-c-api
	cd gcc-c-api && make $(if $(srcdir),-f $(srcdir)./gcc-c-api/Makefile) libgcc-c-api.so CC=$(CC) $(if $(srcdir),srcdir=$(srcdir)./gcc-c-api/)

$(PLUGIN_OBJECT_GENERATED_FILES): CPPFLAGS+= $(if $(srcdir),-I$(srcdir))

# This is the standard .c->.o recipe, but it needs to be stated
# explicitly to support the case that $(srcdir) is not blank.
$(PLUGIN_OBJECT_FILES): %.o: %.c autogenerated-config.h gcc-python.h $(LIBGCC_C_API_SO) autogenerated-EXTRA_CFLAGS.txt
	$(COMPILE.c) $(shell cat autogenerated-EXTRA_CFLAGS.txt) $(OUTPUT_OPTION) -I$(srcdir)./ -I$(srcdir)./gcc-c-api -I./gcc-c-api $<

print-gcc-version: print-gcc-version.c autogenerated-EXTRA_CFLAGS.txt
	$(CC) \
		$(CPPFLAGS) $(CFLAGS) \
		$(shell cat autogenerated-EXTRA_CFLAGS.txt) \
		-o $@ \
		$<

clean:
	$(RM) *.so *.o gcc-c-api/*.o autogenerated*
	$(RM) -r docs/_build
	$(RM) -f gcc-with-$(PLUGIN_NAME).1 gcc-with-$(PLUGIN_NAME).1.gz
	$(RM) -f print-gcc-version
	cd gcc-c-api && make clean
	find tests -name "*.o" -delete

autogenerated-config.h: generate-config-h.py configbuilder.py
	$(PYTHON) $< -o $@ --gcc="$(CC)" --plugindir="$(GCCPLUGINS_DIR)"

autogenerated-%.txt: %.txt.in
	$(CPP) $(CPPFLAGS) -x c-header $^ -o $@

# autogenerated-EXTRA_CFLAGS.txt is a byproduct of making
# autogenerated-config.h:
autogenerated-EXTRA_CFLAGS.txt: autogenerated-config.h

# autogenerated-casts.h is a byproduct of making autogenerated-casts.c
autogenerated-casts.h: autogenerated-casts.c

$(PLUGIN_GENERATED_SOURCE_FILES): autogenerated-%.c: generate-%-c.py $(GENERATOR_DEPS)
	$(PYTHON) $< > $@

autogenerated-casts.c:  autogenerated-gimple-types.txt autogenerated-tree-types.txt autogenerated-rtl-types.txt generate-casts-c.py
	PYTHONPATH=$(srcdir)./gcc-c-api	$(PYTHON) $(srcdir)generate-casts-c.py autogenerated-casts.c autogenerated-casts.h $(xmldir)

autogenerated-gimple.c: autogenerated-gimple-types.txt autogenerated-tree-types.txt autogenerated-rtl-types.txt maketreetypes.py
autogenerated-tree.c: autogenerated-tree-types.txt maketreetypes.py
autogenerated-rtl.c: autogenerated-rtl-types.txt maketreetypes.py
autogenerated-variable.c: autogenerated-gimple-types.txt maketreetypes.py

bindir=/usr/bin
mandir=/usr/share/man

UpperPluginName = $(shell $(PYTHON) -c"print('$(PLUGIN_NAME)'.upper())")

docs/_build/man/gcc-with-python.1: docs/gcc-with-python.rst
	cd docs && $(MAKE) man

gcc-with-$(PLUGIN_NAME).1: docs/_build/man/gcc-with-python.1
	# Fixup the generic manpage for this build:
	cp docs/_build/man/gcc-with-python.1 gcc-with-$(PLUGIN_NAME).1
	sed \
	   -i \
	   -e"s|gcc-with-python|gcc-with-$(PLUGIN_NAME)|g" \
	   gcc-with-$(PLUGIN_NAME).1
	sed \
	   -i \
	   -e"s|GCC-WITH-PYTHON|GCC-WITH-$(UpperPluginName)|g" \
	   gcc-with-$(PLUGIN_NAME).1

gcc-with-$(PLUGIN_NAME).1.gz: gcc-with-$(PLUGIN_NAME).1
	rm -f gcc-with-$(PLUGIN_NAME).1.gz
	gzip gcc-with-$(PLUGIN_NAME).1

man: gcc-with-$(PLUGIN_NAME).1.gz

install: $(PLUGIN_DSO) gcc-with-$(PLUGIN_NAME).1.gz
	mkdir -p $(DESTDIR)$(GCCPLUGINS_DIR)

	cd gcc-c-api && $(MAKE) install

	cp $(PLUGIN_DSO) $(DESTDIR)$(GCCPLUGINS_DIR)

	mkdir -p $(DESTDIR)$(GCCPLUGINS_DIR)/$(PLUGIN_DIR)
	cp -a gccutils $(DESTDIR)$(GCCPLUGINS_DIR)/$(PLUGIN_DIR)
	cp -a libcpychecker $(DESTDIR)$(GCCPLUGINS_DIR)/$(PLUGIN_DIR)

	# Create "gcc-with-" support script:
	mkdir -p $(DESTDIR)$(bindir)
	install -m 755 gcc-with-python $(DESTDIR)/$(bindir)/gcc-with-$(PLUGIN_NAME)
	# Fixup the reference to the plugin in that script, from being expressed as
	# a DSO filename with a path (for a working copy) to a name of an installed
	# plugin within GCC's search directory:
	sed \
	    -i \
	    -e"s|-fplugin=[^ ]*|-fplugin=$(PLUGIN_NAME)|" \
	    $(DESTDIR)$(bindir)/gcc-with-$(PLUGIN_NAME)

        # Fixup the plugin name within -fplugin-arg-PLUGIN_NAME-script to match the
	# name for this specific build:
	sed \
	   -i \
	   -e"s|-fplugin-arg-python-script|-fplugin-arg-$(PLUGIN_NAME)-script|" \
	   $(DESTDIR)$(bindir)/gcc-with-$(PLUGIN_NAME)

	mkdir -p $(DESTDIR)$(mandir)/man1
	cp gcc-with-$(PLUGIN_NAME).1.gz $(DESTDIR)$(mandir)/man1


# Hint for debugging: add -v to the gcc options 
# to get a command line for invoking individual subprocesses
# Doing so seems to require that paths be absolute, rather than relative
# to this directory
TEST_CFLAGS= \
  -fplugin=$(CURDIR)/$(PLUGIN_DSO) \
  -fplugin-arg-python-script=test.py

# A catch-all test for quick experimentation with the API:
test: plugin
	$(INVOCATION_ENV_VARS) $(CC) -v $(TEST_CFLAGS) $(CURDIR)/test.c

# Selftest for the cpychecker.py code:
testcpychecker: plugin
	$(INVOCATION_ENV_VARS) $(PYTHON) $(srcdir)./testcpychecker.py -v

# Selftest for the cpybuilder code:
testcpybuilder:
	$(PYTHON) $(srcdir)./testcpybuilder.py -v

# Selftest for the dejagnu.py code:
testdejagnu:
	$(PYTHON) $(srcdir)./dejagnu.py -v

dump_gimple:
	$(CC) -fdump-tree-gimple $(CURDIR)/test.c

debug: plugin
	$(INVOCATION_ENV_VARS) $(CC) -v $(TEST_CFLAGS) $(CURDIR)/test.c

$(pwd)/gcc-with-cpychecker: gcc-with-cpychecker
	cp $< $@

# A simple demo, to make it easy to demonstrate the cpychecker:
demo: demo.c plugin $(pwd)/gcc-with-cpychecker
	$(INVOCATION_ENV_VARS) ./gcc-with-cpychecker -c $(PYTHON_INCLUDES) $<

# Run 'demo', and verify the output.
testdemo: DEMO_REF=$(shell \
	if [ $$(./print-gcc-version) -ge 7000 ]; then \
		echo demo.expected.no-refcounts; \
	else \
		echo demo.expected; \
	fi)
testdemo: plugin print-gcc-version
	$(MAKE) -f $(srcdir)./Makefile demo > demo.out 2> demo.err
	egrep '^.*demo.c:( In function |[0-9][0-9]*:[0-9][0-9]*: warning:)' \
	  demo.err \
	  | sed 's/:[0-9][0-9]*: warning:/:: warning:/;s/ \[enabled by default\]//' \
	  | sed "s%$(srcdir)demo.c:%demo.c:%g" \
	  > demo.filtered
	diff $(srcdir)./$(DEMO_REF) demo.filtered
	rm demo.out demo.err demo.filtered

json-examples: plugin
	$(INVOCATION_ENV_VARS) $(srcdir)./gcc-with-cpychecker -I/usr/include/python2.7 -c libcpychecker_html/test/example1/bug.c

test-suite: plugin print-gcc-version testdejagnu testdemo
	$(INVOCATION_ENV_VARS) $(PYTHON) $(srcdir)./run-test-suite.py $(if $(srcdir),--srcdir=$(srcdir)) || true

show-ssa: plugin
	$(INVOCATION_ENV_VARS) $(srcdir)./gcc-with-python examples/show-ssa.py test.c

demo-show-lto-supergraph: plugin
	$(INVOCATION_ENV_VARS) $(srcdir)./gcc-with-python \
	  examples/show-lto-supergraph.py \
	  -flto \
	  -flto-partition=none \
	  tests/examples/lto/input-*.c

html: docs/tables-of-passes.rst docs/passes.svg
	cd docs && $(MAKE) html

# We commit this generated file to SCM to allow the docs to be built without
# needing to build the plugin:
docs/tables-of-passes.rst: plugin generate-tables-of-passes-rst.py
	$(INVOCATION_ENV_VARS) $(srcdir)./gcc-with-python generate-tables-of-passes-rst.py test.c > $@

# Likewise for this generated file:
docs/passes.svg: plugin generate-passes-svg.py
	$(INVOCATION_ENV_VARS) $(srcdir)./gcc-with-python generate-passes-svg.py test.c

check-api:
	xmllint --noout --relaxng $(srcdir)./gcc-c-api/api.rng $(srcdir)./gcc-c-api/*.xml

# Utility target, to help me to make releases
#   - creates a tag in git (but does not push it; see "Notes to self on
#     making a release" below)
#   - creates a tarball
#
# The following assumes that VERSION has been set e.g.
#   $ make tarball VERSION=0.4

$(HOME)/rpmbuild/SOURCES/%.tar.gz:
	test -n "$(VERSION)"
	-git tag -d v$(VERSION)
	git tag -a v$(VERSION) -m"$(VERSION)"
	git archive --format=tar --prefix=$*/ v$(VERSION) | gzip > $*.tar.gz
	sha256sum $*.tar.gz
	cp $*.tar.gz $@

tarball: $(HOME)/rpmbuild/SOURCES/gcc-python-plugin-$(VERSION).tar.gz

# Notes to self on making a release
# ---------------------------------
#
#  Before tagging:
#
#     * update the version/release in docs/conf.py
#
#     * update the version in gcc-python-plugin.spec
#
#     * add release notes to docs
#
#  Test the candidate tarball via a scratch SRPM build locally (this
#  achieves test coverage against python 2 and 3, for both debug and
#  optimized python, on one arch, against the locally-installed version of
#  gcc):
#
#     $ make srpm VERSION=fixme
#
#     $ make rpm VERSION=fixme
#
#  Test the candidate tarball via a scratch SRPM build in Koji (this
#  achieves test coverage against python 2 and 3, for both debug and
#  optimized python, on both i686 and x86_64, against another version of
#  gcc):
#
#     $ make koji VERSION=fixme
#
#  After successful testing of a candidate tarball:
#
#   * push the tag:
#
#         $ git push --tags
#
#   * upload it to https://fedorahosted.org/releases/g/c/gcc-python-plugin/
#    via:
#
#        $ scp gcc-python-plugin-$(VERSION).tar.gz dmalcolm@fedorahosted.org:gcc-python-plugin
#
#  * add version to Trac: https://fedorahosted.org/gcc-python-plugin/admin/ticket/versions
#
#  * update release info at https://fedorahosted.org/gcc-python-plugin/wiki#Code
#
#  * send release announcement:
#
#      To: gcc@gcc.gnu.org, gcc-python-plugin@lists.fedorahosted.org, python-announce-list@python.org
#      Subject: ANN: gcc-python-plugin $(VERSION)
#      (etc)
#
#  * build it into Fedora

# Utility target, for building test rpms:
srpm:
	rpmbuild -bs gcc-python-plugin.spec

# Perform a test rpm build locally:
rpm:
	rpmbuild -ba gcc-python-plugin.spec

# Perform a test (scratch) build in Koji:
# The following have been deleted from Koji:
#   f16 was gcc 4.6
#   f17 was gcc 4.7
#   f19 was gcc 4.8
koji-gcc-5: srpm
	koji build --scratch f23 ~/rpmbuild/SRPMS/gcc-python-plugin-$(VERSION)-1.fc20.src.rpm

koji-gcc-6: srpm
	koji build --scratch f24 ~/rpmbuild/SRPMS/gcc-python-plugin-$(VERSION)-1.fc20.src.rpm

koji: koji-gcc-5 koji-gcc-6
