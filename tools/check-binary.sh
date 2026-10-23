#!/usr/bin/env bash
# Verifies a built module before it is shipped:
#   - exports exactly MTA's module entry points (everything else, incl. OpenSSL/libpq, hidden)
#   - no unresolved symbols besides glibc (Lua is resolved at runtime from the server)
#   - depends only on glibc libraries, at most GLIBC_2.31
#   - linked -z nodelete (stays mapped after unloadmodule)
# Usage: tools/check-binary.sh build/release/ml_pgsql.so
set -euo pipefail
so=${1:?usage: tools/check-binary.sh path/to/ml_pgsql.so}
fail() { echo "check-binary: $*" >&2; exit 1; }

expected="DoPulse InitModule RegisterFunctions ResourceStopped ResourceStopping ShutdownModule"
exports=$(nm -D --defined-only "$so" | awk '{print $3}' | sort | xargs)
[ "$exports" = "$expected" ] || fail "unexpected exports: $exports"

# objdump prints symbol versions on every binutils release (older nm -D does not)
undefined=$(objdump -T "$so" | grep '\*UND\*' | grep -v 'GLIBC_' | awk '{print $NF}' | grep -Ev '^(__gmon_start__|_ITM_.*)$' | xargs || true)
[ -z "$undefined" ] || fail "unexpected undefined symbols: $undefined"

needed=$(readelf -d "$so" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | xargs)
for lib in $needed; do
    case "$lib" in
        libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | ld-linux-*.so.*) ;;
        *) fail "unexpected dependency: $lib" ;;
    esac
done

glibc=$(objdump -T "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
printf '%s\n2.31\n' "$glibc" | sort -CV || fail "requires glibc $glibc (newer than 2.31)"

readelf -d "$so" | grep -q NODELETE || fail "not linked with -z nodelete"

echo "check-binary: ok ($so): exports [$exports], needs [$needed], glibc >= $glibc"
