# Build environment for ml_pgsql (Linux x64; also builds natively for arm64 with
# `docker build --platform linux/arm64`).
#
# Ubuntu 20.04 (glibc 2.31, GCC 10): the module only depends on glibc symbols available in
# 2.31, so it loads on Ubuntu 20.04+, Debian 11+ and anything newer. OpenSSL and libpq are
# built as static PIC archives and linked into the module, so the server host needs no
# PostgreSQL/OpenSSL packages.

FROM ubuntu:20.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        gcc-10 g++-10 make cmake perl flex bison curl ca-certificates bzip2 file binutils libc6-dev \
 && rm -rf /var/lib/apt/lists/*
ENV CC=gcc-10 CXX=g++-10

FROM base AS deps

ARG OPENSSL_VERSION=3.5.9
ARG OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ARG PG_VERSION=18.6
ARG PG_SHA256=555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f

ENV PREFIX=/opt/deps
WORKDIR /build

RUN curl -fsSL -o openssl.tar.gz \
        https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz \
 && echo "${OPENSSL_SHA256}  openssl.tar.gz" | sha256sum -c - \
 && tar xzf openssl.tar.gz && cd openssl-${OPENSSL_VERSION} \
 && case "$(uname -m)" in aarch64) target=linux-aarch64 ;; *) target=linux-x86_64 ;; esac \
 && ./Configure "$target" --prefix=${PREFIX} --libdir=lib --openssldir=/etc/ssl \
        no-shared no-module no-dso no-engine no-legacy no-tests no-apps no-docs no-comp \
        no-ssl3 no-dtls -fPIC -O2 \
 && make -j"$(nproc)" build_libs >/dev/null \
 && make install_dev >/dev/null \
 && mkdir -p ${PREFIX}/licenses && cp LICENSE.txt ${PREFIX}/licenses/OpenSSL-LICENSE.txt \
 && cd .. && rm -rf openssl-${OPENSSL_VERSION} openssl.tar.gz

RUN curl -fsSL -o pg.tar.bz2 https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2 \
 && echo "${PG_SHA256}  pg.tar.bz2" | sha256sum -c - \
 && tar xjf pg.tar.bz2 && cd postgresql-${PG_VERSION} \
 && ./configure --prefix=${PREFIX} --with-ssl=openssl --without-readline --without-icu \
        --without-zlib --without-zstd --without-lz4 --without-gssapi \
        CFLAGS="-O2 -fPIC" CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib" \
        LIBS="-lpthread -ldl" >/dev/null \
 && make -C src/include -j"$(nproc)" >/dev/null \
 && make -C src/common -j"$(nproc)" >/dev/null \
 && make -C src/port -j"$(nproc)" >/dev/null \
 && make -C src/interfaces/libpq -j"$(nproc)" all-static-lib >/dev/null \
 && mkdir -p ${PREFIX}/include ${PREFIX}/lib \
 && cp src/interfaces/libpq/libpq.a src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a ${PREFIX}/lib/ \
 && cp src/interfaces/libpq/libpq-fe.h src/interfaces/libpq/libpq-events.h src/include/postgres_ext.h ${PREFIX}/include/ \
 && (cp src/include/pg_config_ext.h ${PREFIX}/include/ 2>/dev/null || true) \
 && cp COPYRIGHT ${PREFIX}/licenses/PostgreSQL-COPYRIGHT.txt \
 && cd .. && rm -rf postgresql-${PG_VERSION} pg.tar.bz2

FROM base
COPY --from=deps /opt/deps /opt/deps
ENV PG_DEPS_PREFIX=/opt/deps
WORKDIR /src
