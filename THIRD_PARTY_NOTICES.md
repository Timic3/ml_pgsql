# Third-party software

`ml_pgsql.so` contains, or is built from, the following third-party software. Release
archives ship the full license texts in `licenses/`.

| Component | Version | Used as | License | License text |
|---|---|---|---|---|
| [libpq](https://www.postgresql.org/) (PostgreSQL client library) | 18.6 | statically linked | PostgreSQL License | `licenses/PostgreSQL-COPYRIGHT.txt` (from the source tarball's `COPYRIGHT`) |
| [OpenSSL](https://www.openssl.org/) | 3.5.9 | statically linked | Apache License 2.0 | `licenses/OpenSSL-LICENSE.txt` (from the source tarball's `LICENSE.txt`) |
| [Lua](https://www.lua.org/) 5.1, as modified by MTA:SA | — | headers (`src/lua/`); the test harness compiles MTA's copy (`tests/harness/vendor/mta-lua/`) | MIT | at the end of `src/lua/lua.h` |
| [MTA:SA](https://github.com/multitheftauto/mtasa-blue) public module SDK | — | `src/sdk/ILuaModuleManager.h` | zlib-style license that **excludes commercial applications** | `src/sdk/LICENSE`, `licenses/MTA-SDK.txt` |

The C++ runtime (libstdc++, libgcc) is linked statically under the GCC Runtime Library
Exception.

Where the binaries come from: `docker/build.Dockerfile` downloads OpenSSL and PostgreSQL
source releases, verifies their SHA-256 checksums, and builds them inside the image.
