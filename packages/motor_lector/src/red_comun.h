// Piezas comunes de las redes neuronales propias (inferencia en C++ sin
// librerias): pesos en float16 y convolucion 1D con dilatacion + ReLU.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace red {

inline float mitad(uint16_t h) {
  const uint32_t signo = (h & 0x8000u) << 16;
  uint32_t exp = (h >> 10) & 0x1f, man = h & 0x3ffu;
  uint32_t bits;
  if (exp == 0) {
    if (man == 0) {
      bits = signo;
    } else { // subnormal
      exp = 127 - 15 + 1;
      while ((man & 0x400u) == 0) {
        man <<= 1;
        exp--;
      }
      man &= 0x3ffu;
      bits = signo | (exp << 23) | (man << 13);
    }
  } else if (exp == 31) {
    bits = signo | 0x7f800000u | (man << 13);
  } else {
    bits = signo | ((exp + 127 - 15) << 23) | (man << 13);
  }
  float f;
  std::memcpy(&f, &bits, 4);
  return f;
}

inline std::vector<float> aFloat(const uint16_t* p, int n) {
  std::vector<float> v(n);
  for (int i = 0; i < n; i++) v[i] = mitad(p[i]);
  return v;
}

// Convolucion 1D (mismo largo, relleno con ceros), entrada [cin][n] ->
// salida [cout][n]. [relu]: aplica ReLU.
inline void conv1d(const float* w, const float* b, int cin, int cout, int k, int dil, const float* in, int n,
                   float* out, bool relu = true) {
  const int p = dil * (k / 2);
  for (int c = 0; c < cout; c++) {
    float* o = out + (size_t)c * n;
    std::fill(o, o + n, b[c]);
    for (int ci = 0; ci < cin; ci++) {
      const float* x = in + (size_t)ci * n;
      for (int j = 0; j < k; j++) {
        const float wv = w[((size_t)c * cin + ci) * k + j];
        const int d = j * dil - p;
        const int desde = std::max(0, -d), hasta = std::min(n, n - d);
        for (int t = desde; t < hasta; t++) o[t] += wv * x[t + d];
      }
    }
    if (relu)
      for (int t = 0; t < n; t++) o[t] = std::max(0.0f, o[t]);
  }
}

} // namespace red
