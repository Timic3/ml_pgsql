#!/usr/bin/env bash
# Packages a built module with its documentation and third-party licenses:
#   dist/ml_pgsql-<version>-linux-<arch>.tar.gz
# Usage: tools/package.sh x64|arm64 [toolchain-image]
# The toolchain image (docker/build.Dockerfile) provides the OpenSSL/PostgreSQL license texts.
set -euo pipefail
cd "$(dirname "$0")/.."

arch=${1:?usage: tools/package.sh x64|arm64 [toolchain-image]}
case "$arch" in
    x64)   so=build/release/ml_pgsql.so; platform=linux/amd64; image=${2:-ml_pgsql-build:latest} ;;
    arm64) so=build/arm64/ml_pgsql.so;   platform=linux/arm64; image=${2:-ml_pgsql-build:arm64} ;;
    *)     echo "usage: $0 x64|arm64 [toolchain-image]" >&2; exit 2 ;;
esac
[ -f "$so" ] || { echo "$so not found; run ./build.sh $arch first" >&2; exit 1; }

version=$(sed -n 's/^#define MLPG_VERSION_STRING "\(.*\)"/\1/p' src/module.h)
name="ml_pgsql-$version-linux-$arch"
stage="dist/$name"
rm -rf "$stage" "dist/$name.tar.gz"
mkdir -p "$stage/licenses"

cp "$so" "$stage/ml_pgsql.so"
cp README.md THIRD_PARTY_NOTICES.md "$stage/"
[ -f LICENSE ] && cp LICENSE "$stage/"
cp src/sdk/LICENSE "$stage/licenses/MTA-SDK.txt"
docker run --rm --platform "$platform" -u "$(id -u):$(id -g)" -v "$PWD/$stage/licenses":/out "$image" \
    sh -c 'cp /opt/deps/licenses/* /out/'
[ -f "$stage/licenses/OpenSSL-LICENSE.txt" ] && [ -f "$stage/licenses/PostgreSQL-COPYRIGHT.txt" ] \
    || { echo "license texts missing from $image (rebuild it from docker/build.Dockerfile)" >&2; exit 1; }

tar -C dist -czf "dist/$name.tar.gz" "$name"
rm -rf "$stage"
echo "dist/$name.tar.gz"
