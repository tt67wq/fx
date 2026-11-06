# quickjs-ng (vendored)

QuickJS JavaScript engine, quickjs-ng fork: https://github.com/quickjs-ng/quickjs

## Locked version

- Release tag: v0.18.0
- Commit: d7215b0ad3fc2c562e8317fd9bca058fd4863804

## What is vendored

Only the files needed to compile the engine library (the same source set the
upstream CMakeLists.txt uses for its qjs library target):

- Sources: dtoa.c, libregexp.c, libunicode.c, quickjs.c
- Headers: cutils.h, list.h, quickjs.h, quickjs-atom.h, quickjs-opcode.h,
  quickjs-c-atomics.h, libregexp.h, libregexp-opcode.h, libunicode.h,
  libunicode-table.h, dtoa.h, builtin-array-fromasync.h,
  builtin-iterator-zip-keyed.h, builtin-iterator-zip.h
- LICENSE, this README

The quickjs-libc.c POSIX bindings and the CLI tools (qjs, qjsc, run-test262)
are not vendored: fx embeds the engine without the upstream libc module.

## How fx builds it

build.zig compiles the four C sources directly into the fx binary with
-DNDEBUG -D_GNU_SOURCE (the flags the T-5 size-spike measured). The engine is
linked but never initialized on any startup path; the codemode sandbox
runtime activates it lazily.

## Update policy

- Follow quickjs-ng release tags. Do not track main.
- To upgrade: replace the vendored files with the new tag's sources, update
  the tag and commit here, rerun the upstream test suite (tests/ via the
  upstream ctest runner), rerun fx's own test suite, and re-check the
  stripped ReleaseSafe binary size against the baseline recorded in
  .agents/tasks/T-9/report.md before committing.
