# Motor de lectura C++ (src/) + zxing-cpp (src/zxing-cpp/core/src), compilados
# en el pod. Classes/ tiene enlaces a esas fuentes (CocoaPods no acepta rutas
# fuera de la carpeta del pod) y un Version.h ya generado.
Pod::Spec.new do |s|
  s.name             = 'motor_lector'
  s.version          = '0.1.0'
  s.summary          = 'Motor de lectura de codigos de barras (C++, zxing-cpp).'
  s.description      = 'Lee codigos de barras dificiles (poca luz, reflejos, invertidos, rotados) con zxing-cpp y preparacion de imagen.'
  s.homepage         = 'https://github.com/Mapers/difar-app-logistica'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'DIFAR' => 'sistemas@difar.pe' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/*.{h,cpp}', 'Classes/zxing/**/*.{h,hpp,c,cpp}'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.library = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'GCC_OPTIMIZATION_LEVEL' => '3',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/Classes" "${PODS_TARGET_SRCROOT}/Classes/zxing"',
  }
  s.swift_version = '5.0'
end
