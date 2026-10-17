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
  "ean_gris.cpp"
)
target_link_libraries(motor_lector PRIVATE ZXing::ZXing)

# Detector de OpenCV (ubica codigos 1D), enlazado estatico con solo core,
# imgproc y objdetect. Se usa el que deja scripts/preparar_opencv.sh en
# third_party/opencv-android (solo arm64-v8a), o -DML_OPENCV_DIR=<carpeta con
# OpenCVConfig.cmake>. Sin OpenCV el motor funciona igual, sin ese paso.
set(ML_OPENCV_LOCAL "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/opencv-android/sdk/native/jni")
if (NOT ML_OPENCV_DIR AND ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a" AND EXISTS "${ML_OPENCV_LOCAL}/OpenCVConfig.cmake")
  set(ML_OPENCV_DIR "${ML_OPENCV_LOCAL}")
endif()
if (ML_OPENCV_DIR)
  message(STATUS "motor_lector: con OpenCV de ${ML_OPENCV_DIR}")
  set(OpenCV_STATIC ON)
  set(OpenCV_DIR ${ML_OPENCV_DIR})
  find_package(OpenCV REQUIRED COMPONENTS core imgproc objdetect)
  target_sources(motor_lector PRIVATE "detector.cpp")
  target_compile_definitions(motor_lector PRIVATE ML_CON_OPENCV)
  target_include_directories(motor_lector PRIVATE ${OpenCV_INCLUDE_DIRS})
  target_link_libraries(motor_lector PRIVATE ${OpenCV_LIBS})
endif()
# Siempre optimizado: en Debug el motor seria 5-10x mas lento.
target_compile_options(motor_lector PRIVATE -O3)
target_compile_options(ZXing PRIVATE -O3)

set_target_properties(motor_lector PROPERTIES
  PUBLIC_HEADER motor_lector.h
  OUTPUT_NAME "motor_lector"
)

target_compile_definitions(motor_lector PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Camara nativa: el analizador de CameraX llama al motor por JNI.
  target_sources(motor_lector PRIVATE "jni_camara.cpp")
  # Android 15: paginas de 16 KB.
  target_link_options(motor_lector PRIVATE "-Wl,-z,max-page-size=16384")
  # Biblioteca estandar de C++ dentro del .so (no hay otra en la app).
  target_link_options(motor_lector PRIVATE "-static-libstdc++")
  # Solo lo que se usa de zxing y OpenCV termina en el .so.
  target_compile_options(motor_lector PRIVATE -ffunction-sections -fdata-sections)
  target_link_options(motor_lector PRIVATE "-Wl,--gc-sections" "-Wl,--exclude-libs,ALL" "-s")
endif()
