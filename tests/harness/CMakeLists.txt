cmake_minimum_required(VERSION 3.16)
project(mlpg_harness LANGUAGES C CXX)

# Fake MTA server for running ml_pgsql under sanitizers / valgrind.
#   mtaserver_fake  - executable without Lua; dlopen()s libfakehost.so RTLD_LOCAL
#   libfakehost.so  - MTA's Lua 5.1 (built as C, like the server) + fake ILuaModuleManager10
#                     + resource/VM lifecycle + scenario driver

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()

set(HARNESS_SANITIZE "" CACHE STRING "Sanitizers for the host and Lua, e.g. address,undefined or thread")
option(HARNESS_LUA_APICHECK "Build Lua with LUA_USE_APICHECK (MTA's crash-on-API-misuse checks)" ON)

set(LUA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/mta-lua)
set(MLPG_SDK ${CMAKE_CURRENT_SOURCE_DIR}/../../src/sdk)
file(GLOB LUA_SOURCES ${LUA_DIR}/*.c)

add_library(fakehost SHARED host/fakehost.cpp host/proxy.cpp ${LUA_SOURCES})
# deathmatch.so is built with -fvisibility=hidden; only LUA_API (LUA_BUILD_AS_DLL) is exported
set_target_properties(fakehost PROPERTIES C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden)
target_include_directories(fakehost PRIVATE ${LUA_DIR} ${MLPG_SDK} host)
target_compile_definitions(fakehost PRIVATE $<$<COMPILE_LANGUAGE:C>:LUA_BUILD_AS_DLL>)
if(HARNESS_LUA_APICHECK)
  target_compile_definitions(fakehost PRIVATE $<$<COMPILE_LANGUAGE:C>:LUA_USE_APICHECK>)
endif()
target_compile_options(fakehost PRIVATE -O1 -g $<$<COMPILE_LANGUAGE:C>:-w> $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wno-unused-function>)
target_link_libraries(fakehost PRIVATE dl pthread m)

add_executable(mtaserver_fake host/runner.c)
target_compile_options(mtaserver_fake PRIVATE -O1 -g)
target_link_libraries(mtaserver_fake PRIVATE dl)

if(HARNESS_SANITIZE)
  foreach(t fakehost mtaserver_fake)
    target_compile_options(${t} PRIVATE -fsanitize=${HARNESS_SANITIZE} -fno-omit-frame-pointer)
    target_link_options(${t} PRIVATE -fsanitize=${HARNESS_SANITIZE})
  endforeach()
endif()
