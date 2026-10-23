cmake_minimum_required(VERSION 3.16)
project(ml_pgsql LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Static deps (release builds): a prefix containing libpq.a, libpgcommon_shlib.a,
# libpgport_shlib.a, libssl.a, libcrypto.a (see docker/build.Dockerfile).
set(PG_DEPS_PREFIX "$ENV{PG_DEPS_PREFIX}" CACHE PATH "Prefix with static libpq/OpenSSL")
# address | thread | undefined (development only; links the system libpq dynamically)
set(MLPG_SANITIZE "" CACHE STRING "Sanitizer to build with")

add_library(ml_pgsql MODULE
  src/bindings.cpp
  src/convert.cpp
  src/lua_api.cpp
  src/module.cpp
  src/pool.cpp
)
set_target_properties(ml_pgsql PROPERTIES
  PREFIX ""
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)
target_include_directories(ml_pgsql PRIVATE src src/lua)
target_compile_options(ml_pgsql PRIVATE
  -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-overloaded-virtual
  -fstack-protector-strong -ffunction-sections -fdata-sections
)
target_compile_definitions(ml_pgsql PRIVATE $<$<CONFIG:Release>:_FORTIFY_SOURCE=2>)
target_link_options(ml_pgsql PRIVATE
  -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/exports.map
  -Wl,--no-undefined
  -Wl,-z,relro,-z,now,-z,noexecstack
  # Stay mapped after dlclose (unloadmodule): scripts may still hold references to our
  # functions, which then fail cleanly instead of jumping into unmapped memory.
  -Wl,-z,nodelete
)

if(MLPG_SANITIZE)
  find_package(PostgreSQL REQUIRED)
  target_link_libraries(ml_pgsql PRIVATE PostgreSQL::PostgreSQL pthread dl)
  target_compile_options(ml_pgsql PRIVATE -fsanitize=${MLPG_SANITIZE} -fno-omit-frame-pointer -g -O1)
  target_link_options(ml_pgsql PRIVATE -fsanitize=${MLPG_SANITIZE})
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    # clang only links sanitizer runtimes into executables; depend on the shared runtime
    # instead (GCC links the shared runtime into shared objects by default).
    target_link_options(ml_pgsql PRIVATE -shared-libsan)
  endif()
  # the sanitizer runtime is provided by the host process; allow its symbols to resolve late
  target_link_options(ml_pgsql PRIVATE -Wl,--allow-shlib-undefined)
elseif(PG_DEPS_PREFIX)
  target_include_directories(ml_pgsql PRIVATE ${PG_DEPS_PREFIX}/include)
  target_link_libraries(ml_pgsql PRIVATE
    ${PG_DEPS_PREFIX}/lib/libpq.a
    ${PG_DEPS_PREFIX}/lib/libpgcommon_shlib.a
    ${PG_DEPS_PREFIX}/lib/libpgport_shlib.a
    ${PG_DEPS_PREFIX}/lib/libssl.a
    ${PG_DEPS_PREFIX}/lib/libcrypto.a
    pthread dl m
  )
  # Everything static and hidden: the module cannot clash with other modules' (or the
  # server's) copies of OpenSSL/libstdc++, and needs nothing installed on the host.
  target_link_options(ml_pgsql PRIVATE -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL -Wl,--gc-sections -s)
else()
  find_package(PostgreSQL REQUIRED)
  target_link_libraries(ml_pgsql PRIVATE PostgreSQL::PostgreSQL pthread dl)
endif()
