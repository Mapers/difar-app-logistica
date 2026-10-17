#include "red_restaurar.h"

#include "red_comun.h"
#include "red_restaurar_pesos.h"

#include <cmath>
#include <mutex>

namespace red {
namespace {

struct Capa {
  int cin, cout, k, dil;
};
// Igual que CAPAS en entrenar_rest.py, y la capa de salida.
constexpr Capa kCapas[] = {{1, 24, 9, 1}, {24, 32, 7, 1}, {32, 32, 5, 2}, {32, 32, 5, 4}, {32, 32, 5, 8}, {32, 24, 5, 1}};
constexpr Capa kSalida = {24, 1, 3, 1};

constexpr int pesosEsperados() {
  int n = 0;
  for (const auto& c : kCapas) n += c.cout * c.cin * c.k + c.cout;
  return n + kSalida.cout * kSalida.cin * kSalida.k + kSalida.cout;
}

const std::vector<float>& pesos() {
  static std::vector<float> p;
  static std::once_flag listo;
  std::call_once(listo, [] { p = aFloat(kRedRestaurarPesos, kRedRestaurarTotal); });
  return p;
}

} // namespace

void inferirRestaurar(const float* perfil, float* prob) {
  const float* p = pesos().data();
  constexpr int n = kLargoRestaurar;
  float media = 0, var = 0;
  for (int i = 0; i < n; i++) media += perfil[i];
  media /= n;
  for (int i = 0; i < n; i++) var += (perfil[i] - media) * (perfil[i] - media);
  const float desvio = std::sqrt(var / n) + 4.0f;
  thread_local std::vector<float> a(32 * n), b(32 * n);
  for (int i = 0; i < n; i++) a[i] = (perfil[i] - media) / desvio;
  for (const auto& c : kCapas) {
    const float* w = p;
    p += (size_t)c.cout * c.cin * c.k;
    const float* bias = p;
    p += c.cout;
    conv1d(w, bias, c.cin, c.cout, c.k, c.dil, a.data(), n, b.data());
    std::swap(a, b);
  }
  const float* w = p;
  p += kSalida.cin * kSalida.k;
  conv1d(w, p, kSalida.cin, 1, kSalida.k, 1, a.data(), n, b.data(), false);
  for (int i = 0; i < n; i++) prob[i] = 1.0f / (1.0f + std::exp(-b[i]));
}

bool restaurar(const prep::Gris& img, std::vector<uint8_t>& barras) {
  if (kRedRestaurarTotal != pesosEsperados() || img.ancho < 40 || img.alto < 4) return false;
  const int y0 = (int)(img.alto * 0.35f), y1 = std::max(y0 + 1, (int)(img.alto * 0.65f));
  std::vector<float> fila(img.ancho, 0);
  for (int y = y0; y < y1; y++)
    for (int x = 0; x < img.ancho; x++) fila[x] += img.px[(size_t)y * img.ancho + x];
  for (auto& v : fila) v /= (float)(y1 - y0);
  float perfil[kLargoRestaurar], prob[kLargoRestaurar];
  for (int i = 0; i < kLargoRestaurar; i++) {
    const float pos = i * (float)(img.ancho - 1) / (kLargoRestaurar - 1);
    const int a = std::min((int)pos, img.ancho - 2);
    const float t = pos - a;
    perfil[i] = fila[a] * (1 - t) + fila[a + 1] * t;
  }
  inferirRestaurar(perfil, prob);
  barras.resize(kLargoRestaurar);
  for (int i = 0; i < kLargoRestaurar; i++) barras[i] = prob[i] > 0.5f ? 1 : 0;
  return true;
}

} // namespace red
