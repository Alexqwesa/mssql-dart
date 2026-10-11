cmake_minimum_required(VERSION 3.24)
project(mssql_tls LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(OPENSSL_USE_STATIC_LIBS TRUE)
find_package(OpenSSL REQUIRED COMPONENTS SSL Crypto)
add_library(mssql_tls SHARED src/mssql_tls.cpp)
target_include_directories(mssql_tls PUBLIC include)
target_link_libraries(mssql_tls PRIVATE OpenSSL::SSL OpenSSL::Crypto)
set_target_properties(mssql_tls PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
)
if(APPLE)
  find_library(CORE_FOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
  find_library(SECURITY_FRAMEWORK Security REQUIRED)
  target_link_libraries(mssql_tls PRIVATE
    ${CORE_FOUNDATION_FRAMEWORK}
    ${SECURITY_FRAMEWORK}
  )
  target_link_options(mssql_tls PRIVATE
    "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/apple_exports.txt"
  )
  set_target_properties(mssql_tls PROPERTIES
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
  )
endif()
if(MSVC)
  target_compile_options(mssql_tls PRIVATE /W4 /WX)
else()
  target_compile_options(mssql_tls PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

include(CTest)
if(BUILD_TESTING)
  add_executable(mssql_tls_tests test/mssql_tls_test.cpp)
  target_link_libraries(mssql_tls_tests PRIVATE mssql_tls OpenSSL::SSL OpenSSL::Crypto)
  add_test(NAME mssql_tls_tests COMMAND mssql_tls_tests)
endif()
