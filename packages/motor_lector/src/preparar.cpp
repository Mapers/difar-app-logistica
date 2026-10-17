#include "preparar.h"

#include <algorithm>
#include <cmath>

namespace prep {

namespace {
inline uint8_t recortar(int v) { return (uint8_t)std::clamp(v, 0, 255); }
} // namespace

Estadistica medir(const uint8_t* px, int ancho, int alto, int fila) {
  const int x0 = ancho / 4, x1 = ancho * 3 / 4, y0 = alto / 4, y1 = alto * 3 / 4;
  int64_t suma = 0, suma2 = 0, n = 0, quemados = 0, bordes = 0;
  for (int y = std::max(y0, 1); y < std::min(y1, alto - 1); y += 4) {
    const uint8_t* f = px + (size_t)y * fila;
    for (int x = std::max(x0, 1); x < std::min(x1, ancho - 1); x += 4) {
      const int v = f[x];
      suma += v;
      suma2 += v * v;
      quemados += v >= 250;
      bordes += std::abs(4 * v - f[x - 1] - f[x + 1] - f[x - fila] - f[x + fila]);
      n++;
    }
  }
  if (n == 0) return {0, 0, 0, 0};
  const double media = (double)suma / n;
  const double var = std::max(0.0, (double)suma2 / n - media * media);
  return {(int)media, (int)std::sqrt(var), (int)(quemados * 100 / n), (int)(bordes / n)};
}

Gris deBgra(const uint8_t* bgra, int ancho, int alto, int fila) {
  Gris g{ancho, alto, std::vector<uint8_t>((size_t)ancho * alto)};
  for (int y = 0; y < alto; y++) {
    const uint8_t* f = bgra + (size_t)y * fila;
    uint8_t* o = g.px.data() + (size_t)y * ancho;
    for (int x = 0; x < ancho; x++) {
      const uint8_t* p = f + x * 4;
      o[x] = (uint8_t)((p[2] * 77 + p[1] * 150 + p[0] * 29) >> 8); // BT.601
    }
  }
  return g;
}

Gris clahe(const uint8_t* px, int ancho, int alto, int fila, int zx, int zy, float limite) {
  zx = std::max(1, std::min(zx, ancho));
  zy = std::max(1, std::min(zy, alto));
  const int tw = (ancho + zx - 1) / zx, th = (alto + zy - 1) / zy;
  std::vector<uint8_t> mapas((size_t)zx * zy * 256);

  for (int ty = 0; ty < zy; ty++) {
    for (int tx = 0; tx < zx; tx++) {
      const int x0 = tx * tw, y0 = ty * th;
      const int x1 = std::min(ancho, x0 + tw), y1 = std::min(alto, y0 + th);
      int hist[256] = {0};
      for (int y = y0; y < y1; y++) {
        const uint8_t* f = px + (size_t)y * fila;
        for (int x = x0; x < x1; x++) hist[f[x]]++;
      }
      const int area = std::max(1, (x1 - x0) * (y1 - y0));
      // Recorta los picos del histograma y reparte el exceso entre todos.
      const int tope = std::max(1, (int)(limite * area / 256));
      int exceso = 0;
      for (int& h : hist)
        if (h > tope) {
          exceso += h - tope;
          h = tope;
        }
      const int reparto = exceso / 256, resto = exceso % 256;
      for (int i = 0; i < 256; i++) hist[i] += reparto + (i < resto ? 1 : 0);

      uint8_t* mapa = &mapas[((size_t)ty * zx + tx) * 256];
      int acumulado = 0;
      for (int i = 0; i < 256; i++) {
        acumulado += hist[i];
        mapa[i] = (uint8_t)std::min(255, acumulado * 255 / area);
      }
    }
  }

  // Interpolacion bilineal entre los mapas de las 4 zonas vecinas (sin bloques).
  Gris g{ancho, alto, std::vector<uint8_t>((size_t)ancho * alto)};
  for (int y = 0; y < alto; y++) {
    const float fy = (y + 0.5f) / th - 0.5f;
    const int ya = std::clamp((int)std::floor(fy), 0, zy - 1), yb = std::min(ya + 1, zy - 1);
    const float wy = std::clamp(fy - ya, 0.0f, 1.0f);
    const uint8_t* f = px + (size_t)y * fila;
    uint8_t* o = g.px.data() + (size_t)y * ancho;
    for (int x = 0; x < ancho; x++) {
      const float fx = (x + 0.5f) / tw - 0.5f;
      const int xa = std::clamp((int)std::floor(fx), 0, zx - 1), xb = std::min(xa + 1, zx - 1);
      const float wx = std::clamp(fx - xa, 0.0f, 1.0f);
      const int v = f[x];
      const float a = mapas[((size_t)ya * zx + xa) * 256 + v], b = mapas[((size_t)ya * zx + xb) * 256 + v];
      const float c = mapas[((size_t)yb * zx + xa) * 256 + v], d = mapas[((size_t)yb * zx + xb) * 256 + v];
      o[x] = (uint8_t)((a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy);
    }
  }
  return g;
}

Gris normalizarLocal(const uint8_t* px, int ancho, int alto, int fila, int radio) {
  // Imagenes integrales de la suma y la suma de cuadrados.
  const int W = ancho + 1;
  std::vector<int64_t> s((size_t)W * (alto + 1), 0), s2((size_t)W * (alto + 1), 0);
  for (int y = 0; y < alto; y++) {
    const uint8_t* f = px + (size_t)y * fila;
    int64_t fs = 0, fs2 = 0;
    for (int x = 0; x < ancho; x++) {
      fs += f[x];
      fs2 += f[x] * f[x];
      s[(size_t)(y + 1) * W + x + 1] = s[(size_t)y * W + x + 1] + fs;
      s2[(size_t)(y + 1) * W + x + 1] = s2[(size_t)y * W + x + 1] + fs2;
    }
  }
  Gris g{ancho, alto, std::vector<uint8_t>((size_t)ancho * alto)};
  for (int y = 0; y < alto; y++) {
    const int ya = std::max(0, y - radio), yb = std::min(alto, y + radio + 1);
    const uint8_t* f = px + (size_t)y * fila;
    uint8_t* o = g.px.data() + (size_t)y * ancho;
    for (int x = 0; x < ancho; x++) {
      const int xa = std::max(0, x - radio), xb = std::min(ancho, x + radio + 1);
      const int64_t n = (int64_t)(xb - xa) * (yb - ya);
      const int64_t sum = s[(size_t)yb * W + xb] - s[(size_t)ya * W + xb] - s[(size_t)yb * W + xa] + s[(size_t)ya * W + xa];
      const int64_t sum2 =
          s2[(size_t)yb * W + xb] - s2[(size_t)ya * W + xb] - s2[(size_t)yb * W + xa] + s2[(size_t)ya * W + xa];
      const float media = (float)sum / n;
      const float desv = std::sqrt(std::max(0.0f, (float)sum2 / n - media * media));
      // Piso de desviacion: en zonas lisas (sin barras) no se amplifica el ruido.
      o[x] = recortar((int)(128 + (f[x] - media) * 60.0f / std::max(desv, 10.0f)));
    }
  }
  return g;
}

Gris afinar1D(const uint8_t* px, int ancho, int alto, int fila, int radioSuave, int radioNorm) {
  // Orientacion: barras verticales dan mucho borde en x y poco en y.
  int64_t bx = 0, by = 0;
  for (int y = 1; y < alto - 1; y += 3) {
    const uint8_t* f = px + (size_t)y * fila;
    for (int x = 1; x < ancho - 1; x += 3) {
      bx += std::abs(f[x + 1] - f[x - 1]);
      by += std::abs(f[x + fila] - f[x - fila]);
    }
  }
  const bool verticales = bx >= by;

  // Promedio movil a lo largo de las barras (suma corrida: costo fijo por pixel).
  Gris s{ancho, alto, std::vector<uint8_t>((size_t)ancho * alto)};
  if (verticales) {
    std::vector<int> suma(ancho, 0);
    for (int y = -radioSuave; y < alto; y++) {
      const int entra = y + radioSuave, sale = y - radioSuave - 1;
      if (entra < alto)
        for (int x = 0; x < ancho; x++) suma[x] += px[(size_t)entra * fila + x];
      if (sale >= 0)
        for (int x = 0; x < ancho; x++) suma[x] -= px[(size_t)sale * fila + x];
      if (y < 0) continue;
      const int n = std::min(alto - 1, y + radioSuave) - std::max(0, y - radioSuave) + 1;
      uint8_t* o = s.px.data() + (size_t)y * ancho;
      for (int x = 0; x < ancho; x++) o[x] = (uint8_t)(suma[x] / n);
    }
  } else {
    for (int y = 0; y < alto; y++) {
      const uint8_t* f = px + (size_t)y * fila;
      uint8_t* o = s.px.data() + (size_t)y * ancho;
      int suma = 0;
      for (int x = -radioSuave; x < ancho; x++) {
        const int entra = x + radioSuave, sale = x - radioSuave - 1;
        if (entra < ancho) suma += f[entra];
        if (sale >= 0) suma -= f[sale];
        if (x < 0) continue;
        const int n = std::min(ancho - 1, x + radioSuave) - std::max(0, x - radioSuave) + 1;
        o[x] = (uint8_t)(suma / n);
      }
    }
  }
  return normalizarLocal(s.px.data(), ancho, alto, ancho, radioNorm);
}

Gris enfocar(const Gris& img, float cantidad) {
  const int w = img.ancho, h = img.alto;
  Gris g{w, h, img.px};
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      int suma = 0;
      for (int dy = -1; dy <= 1; dy++) {
        const uint8_t* f = img.px.data() + (size_t)(y + dy) * w;
        suma += f[x - 1] + f[x] + f[x + 1];
      }
      const int v = img.px[(size_t)y * w + x];
      g.px[(size_t)y * w + x] = recortar((int)(v + cantidad * (v - suma / 9.0f)));
    }
  }
  return g;
}

Gris invertir(const uint8_t* px, int ancho, int alto, int fila) {
  Gris g{ancho, alto, std::vector<uint8_t>((size_t)ancho * alto)};
  for (int y = 0; y < alto; y++) {
    const uint8_t* f = px + (size_t)y * fila;
    uint8_t* o = g.px.data() + (size_t)y * ancho;
    for (int x = 0; x < ancho; x++) o[x] = 255 - f[x];
  }
  return g;
}

Gris rotar45(const uint8_t* px, int ancho, int alto, int fila) {
  const float r = 0.70710678f; // cos 45 = sen 45
  const int lado = (int)((ancho + alto) * r) + 1;
  Gris g{lado, lado, std::vector<uint8_t>((size_t)lado * lado, 128)};
  const float cx = ancho / 2.0f, cy = alto / 2.0f, c = lado / 2.0f;
  for (int y = 0; y < lado; y++) {
    for (int x = 0; x < lado; x++) {
      // Destino -> origen: girar -45 alrededor del centro.
      const float dx = x - c, dy = y - c;
      const float sx = r * (dx + dy) + cx, sy = r * (dy - dx) + cy;
      if (sx < 0 || sy < 0 || sx >= ancho - 1 || sy >= alto - 1) continue;
      const int xa = (int)sx, ya = (int)sy;
      const float wx = sx - xa, wy = sy - ya;
      const uint8_t* f = px + (size_t)ya * fila + xa;
      const float v = (f[0] * (1 - wx) + f[1] * wx) * (1 - wy) + (f[fila] * (1 - wx) + f[fila + 1] * wx) * wy;
      g.px[(size_t)y * lado + x] = (uint8_t)(v + 0.5f);
    }
  }
  return g;
}

Gris ampliar2x(const uint8_t* px, int ancho, int alto, int fila) {
  const int w = ancho * 2, h = alto * 2;
  Gris g{w, h, std::vector<uint8_t>((size_t)w * h)};
  for (int y = 0; y < h; y++) {
    const float fy = std::max(0.0f, (y + 0.5f) / 2 - 0.5f);
    const int ya = std::min((int)fy, alto - 1), yb = std::min(ya + 1, alto - 1);
    const float wy = fy - ya;
    for (int x = 0; x < w; x++) {
      const float fx = std::max(0.0f, (x + 0.5f) / 2 - 0.5f);
      const int xa = std::min((int)fx, ancho - 1), xb = std::min(xa + 1, ancho - 1);
      const float wx = fx - xa;
      const float a = px[(size_t)ya * fila + xa], b = px[(size_t)ya * fila + xb];
      const float c = px[(size_t)yb * fila + xa], d = px[(size_t)yb * fila + xb];
      g.px[(size_t)y * w + x] = (uint8_t)((a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy + 0.5f);
    }
  }
  return g;
}

} // namespace prep
