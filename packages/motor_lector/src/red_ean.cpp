#include "red_ean.h"

#include "red_comun.h"
#include "red_ean_pesos.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

namespace red {
namespace {

constexpr int kLargo = 400;
// Pesos que espera esta arquitectura (si el encabezado no coincide, la red no se usa).
constexpr int kPesosEsperados = (32 * 7 + 32) + (32 * 32 * 5 + 32) + (64 * 32 * 5 + 64) + 2 * (64 * 64 * 3 + 64) +
                                (256 * 1600 + 256) + (131 * 256 + 131);

// Umbrales medidos con perfiles sinteticos de validacion (ver el banco).
constexpr float kMinEsEan = 0.9f;
constexpr float kMinDigito = 0.6f;
constexpr float kMinMargen = 2.0f; // log: la segunda combinacion valida es >7 veces menos probable

const std::vector<float>& pesos() {
  static std::vector<float> p;
  static std::once_flag listo;
  std::call_once(listo, [] {
    p.resize(kRedEanTotal);
    for (int i = 0; i < kRedEanTotal; i++) p[i] = mitad(kRedEanPesos[i]);
  });
  return p;
}

void maxpool(const float* in, int canales, int n, float* out) {
  for (int c = 0; c < canales; c++)
    for (int t = 0; t < n / 2; t++) out[(size_t)c * (n / 2) + t] = std::max(in[(size_t)c * n + 2 * t], in[(size_t)c * n + 2 * t + 1]);
}

// Digitos con el verificador valido de mayor probabilidad conjunta.
// [prohibida]/[digito]: posicion y valor que no se pueden usar.
float mejorValida(const float* logp, int* digitos, int prohibida = -1, int digito = -1) {
  float costo[14][10];
  int atras[14][10];
  for (auto& f : costo) std::fill(f, f + 10, -1e30f);
  costo[0][0] = 0;
  for (int i = 0; i < 13; i++) {
    const int peso = (i < 12 && i % 2 == 1) ? 3 : 1;
    for (int m = 0; m < 10; m++) {
      if (costo[i][m] < -1e29f) continue;
      for (int d = 0; d < 10; d++) {
        if (i == prohibida && d == digito) continue;
        const int nm = (m + peso * d) % 10;
        const float c = costo[i][m] + logp[i * 10 + d];
        if (c > costo[i + 1][nm]) {
          costo[i + 1][nm] = c;
          atras[i + 1][nm] = m * 10 + d;
        }
      }
    }
  }
  if (costo[13][0] < -1e29f) return -1e30f;
  if (digitos) {
    for (int i = 13, m = 0; i > 0; i--) {
      digitos[i - 1] = atras[i][m] % 10;
      m = atras[i][m] / 10;
    }
  }
  return costo[13][0];
}

} // namespace

void inferir(const float* perfil, float* salida) {
  const auto& P = pesos();
  // Orden de los pesos (exportar.py): c1..c5 (w, b), fc1 (w, b), fc2 (w, b).
  const float* p = P.data();
  auto tomar = [&](size_t n) {
    const float* r = p;
    p += n;
    return r;
  };
  // Normalizacion igual que al entrenar: (x - media) / (desvio + 4).
  float media = 0, var = 0;
  for (int i = 0; i < kLargo; i++) media += perfil[i];
  media /= kLargo;
  for (int i = 0; i < kLargo; i++) var += (perfil[i] - media) * (perfil[i] - media);
  const float desvio = std::sqrt(var / kLargo) + 4.0f;
  thread_local std::vector<float> a(64 * 400), b(64 * 400);
  for (int i = 0; i < kLargo; i++) a[i] = (perfil[i] - media) / desvio;

  struct Capa {
    int cin, cout, k;
    bool pool;
  };
  const Capa capas[5] = {{1, 32, 7, false}, {32, 32, 5, true}, {32, 64, 5, true}, {64, 64, 3, true}, {64, 64, 3, true}};
  int n = kLargo;
  for (const auto& c : capas) {
    const float* w = tomar((size_t)c.cout * c.cin * c.k);
    const float* bias = tomar(c.cout);
    conv1d(w, bias, c.cin, c.cout, c.k, 1, a.data(), n, b.data());
    if (c.pool) {
      maxpool(b.data(), c.cout, n, a.data());
      n /= 2;
    } else {
      std::swap(a, b);
    }
  }
  // a: [64][25]
  const int entrada = 64 * 25;
  const float* w1 = tomar((size_t)256 * entrada);
  const float* b1 = tomar(256);
  float oculto[256];
  for (int o = 0; o < 256; o++) {
    float s = b1[o];
    const float* w = w1 + (size_t)o * entrada;
    for (int i = 0; i < entrada; i++) s += w[i] * a[i];
    oculto[o] = std::max(0.0f, s);
  }
  const float* w2 = tomar((size_t)131 * 256);
  const float* b2 = tomar(131);
  for (int o = 0; o < 131; o++) {
    float s = b2[o];
    for (int i = 0; i < 256; i++) s += w2[(size_t)o * 256 + i] * oculto[i];
    salida[o] = s;
  }
  // Softmax por digito; sigmoide para "es un EAN".
  for (int d = 0; d < 13; d++) {
    float* v = salida + d * 10;
    const float mx = *std::max_element(v, v + 10);
    float suma = 0;
    for (int i = 0; i < 10; i++) suma += (v[i] = std::exp(v[i] - mx));
    for (int i = 0; i < 10; i++) v[i] /= suma;
  }
  salida[130] = 1.0f / (1.0f + std::exp(-salida[130]));
}

namespace {

bool leerPerfil(const float* perfil, Resultado& r) {
  float s[131];
  inferir(perfil, s);
  if (s[130] < kMinEsEan) return false;
  float logp[130];
  for (int i = 0; i < 130; i++) logp[i] = std::log(std::max(s[i], 1e-9f));
  int d[13];
  const float mejor = mejorValida(logp, d);
  if (mejor < -1e29f) return false;
  float minima = 1;
  for (int i = 0; i < 13; i++) minima = std::min(minima, s[i * 10 + d[i]]);
  if (minima < kMinDigito) return false;
  float segunda = -1e30f;
  for (int i = 0; i < 13; i++) segunda = std::max(segunda, mejorValida(logp, nullptr, i, d[i]));
  const float margen = mejor - segunda;
  if (margen < kMinMargen) return false;
  r.texto.clear();
  for (int i = 0; i < 13; i++) r.texto += (char)('0' + d[i]);
  r.esEan = s[130];
  r.minima = minima;
  r.margen = margen;
  return true;
}

} // namespace

bool leerEan(const prep::Gris& img, Resultado& r) {
  if (kRedEanTotal != kPesosEsperados || img.ancho < 40 || img.alto < 4) return false;
  // Perfil: promedio de las filas del centro, llevado a 400 muestras.
  const int y0 = (int)(img.alto * 0.35f), y1 = std::max(y0 + 1, (int)(img.alto * 0.65f));
  std::vector<float> fila(img.ancho, 0);
  for (int y = y0; y < y1; y++)
    for (int x = 0; x < img.ancho; x++) fila[x] += img.px[(size_t)y * img.ancho + x];
  for (auto& v : fila) v /= (float)(y1 - y0);
  float perfil[kLargo], reves[kLargo];
  for (int i = 0; i < kLargo; i++) {
    const float pos = i * (float)(img.ancho - 1) / (kLargo - 1);
    const int a = std::min((int)pos, img.ancho - 2);
    const float t = pos - a;
    perfil[i] = fila[a] * (1 - t) + fila[a + 1] * t;
  }
  for (int i = 0; i < kLargo; i++) reves[i] = perfil[kLargo - 1 - i];
  Resultado a, b;
  const bool okA = leerPerfil(perfil, a), okB = leerPerfil(reves, b);
  if (!okA && !okB) return false;
  r = okA && (!okB || a.margen >= b.margen) ? a : b;
  return true;
}

} // namespace red
