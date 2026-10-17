# Motor de lectura (C++) + zxing-cpp (solo lectura), compilados juntos en una
# biblioteca nativa que la app llama por FFI.
cmake_minimum_required(VERSION 3.16)

project(motor_lector_library VERSION 0.1.0 LANGUAGES C CXX)

if (NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# zxing-cpp estatico, solo lectores (sin escritura de codigos ni zint).
set(BUILD_SHARED_LIBS OFF)
set(ZXING_READERS ON)
set(ZXING_WRITERS OFF)
add_subdirectory(zxing-cpp/core zxing EXCLUDE_FROM_ALL)

add_library(motor_lector SHARED
  "motor_lector.cpp"
  "preparar.cpp"
)
target_link_libraries(motor_lector PRIVATE ZXing::ZXing)
# Siempre optimizado: en Debug el motor seria 5-10x mas lento.
target_compile_options(motor_lector PRIVATE -O3)
target_compile_options(ZXing PRIVATE -O3)

set_target_properties(motor_lector PROPERTIES
  PUBLIC_HEADER motor_lector.h
  OUTPUT_NAME "motor_lector"
)

target_compile_definitions(motor_lector PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Android 15: paginas de 16 KB.
  target_link_options(motor_lector PRIVATE "-Wl,-z,max-page-size=16384")
  # Biblioteca estandar de C++ dentro del .so (no hay otra en la app).
  target_link_options(motor_lector PRIVATE "-static-libstdc++")
endif()
