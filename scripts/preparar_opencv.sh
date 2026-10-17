#!/usr/bin/env bash
# Compila OpenCV 4.12.0 minimo (core, imgproc, objdetect; sin dnn ni codecs)
# como bibliotecas estaticas para Android arm64-v8a, en
# packages/motor_lector/third_party/opencv-android. El motor lo enlaza solo
# si existe (detector de codigos 1D). Se corre una vez por maquina (~10 min).
#   ANDROID_HOME=/ruta/al/sdk scripts/preparar_opencv.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/packages/motor_lector/third_party/opencv-android"
SDK="${ANDROID_HOME:?Falta ANDROID_HOME}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/27.0.12077973}"
CMAKE_DIR="$SDK/cmake/3.22.1/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -f "$DESTINO/sdk/native/jni/OpenCVConfig.cmake" ]; then
  echo "OpenCV ya esta en $DESTINO"
  exit 0
fi
git clone -q --depth 1 --branch 4.12.0 https://github.com/opencv/opencv.git "$TMP/src"
"$CMAKE_DIR/cmake" -S "$TMP/src" -B "$TMP/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_DIR/ninja" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-23 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_LIST=core,imgproc,objdetect -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_ANDROID_PROJECTS=OFF -DBUILD_ANDROID_EXAMPLES=OFF -DBUILD_JAVA=OFF \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
  -DWITH_PROTOBUF=OFF -DWITH_TBB=OFF -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_ADE=OFF \
  -DBUILD_ZLIB=ON -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
  -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_OPENEXR=OFF -DWITH_IMGCODEC_HDR=OFF \
  -DWITH_KLEIDICV=ON -DCMAKE_INSTALL_PREFIX="$DESTINO"
"$CMAKE_DIR/cmake" --build "$TMP/build"
"$CMAKE_DIR/cmake" --install "$TMP/build"
echo "Listo: $DESTINO"
