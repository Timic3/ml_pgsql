#!/usr/bin/env bash
# Builds ml_pgsql.so in Docker.
#   ./build.sh          -> build/release/ml_pgsql.so  (Linux x64)
#   ./build.sh arm64    -> build/arm64/ml_pgsql.so    (Linux arm64; slow under emulation)
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-x64}" in
    x64)   platform=linux/amd64; tag=latest; out=build/release ;;
    arm64) platform=linux/arm64; tag=arm64;  out=build/arm64 ;;
    *)     echo "usage: $0 [x64|arm64]" >&2; exit 2 ;;
esac

# MLPG_BUILD_IMAGE: use an existing toolchain image instead of building one (CI caches it).
image=${MLPG_BUILD_IMAGE:-}
if [ -z "$image" ]; then
    image="ml_pgsql-build:$tag"
    docker build --platform "$platform" -f docker/build.Dockerfile -t "$image" docker/
fi
docker run --rm --platform "$platform" -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src "$image" \
    sh -c "cmake -S . -B $out -DCMAKE_BUILD_TYPE=Release && cmake --build $out -j\"\$(nproc)\""
echo "-> $out/ml_pgsql.so"
