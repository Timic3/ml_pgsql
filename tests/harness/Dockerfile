# Build + run environment for the ml_pgsql sanitizer harness.
#   gcc 14 (ASan/UBSan/TSan/LSan runtimes), cmake, system libpq 17 (PQsendPipelineSync,
#   PQcancelCreate), valgrind. Used by tests/harness/run.sh; nothing is baked in, the repo is
#   bind-mounted at /src.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build pkg-config \
        libpq-dev valgrind gdb procps postgresql-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
