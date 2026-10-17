#include "ean_gris.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

#ifdef GRIS_DEPURAR
#include <cstdio>
#define DEP(...) std::fprintf(stderr, __VA_ARGS__)
#else
#define DEP(...)
#endif

namespace gris {
namespace {

// Patrones L de EAN/UPC (7 modulos, 1 = barra). R = complemento de L; G = R al reves.
const char* const kL[10] = {"0001101", "0011001", "0010011", "0111101", "0100011",
                            "0110001", "0101111", "0111011", "0110111", "0001011"};
// Paridad de los 6 digitos izquierdos (0 = L, 1 = G) segun el primer digito del EAN-13.
const int kParidad[10] = {0b000000, 0b001011, 0b001101, 0b001110, 0b010011,
                          0b011001, 0b011100, 0b010101, 0b010110, 0b011010};

using Patron = std::array<uint8_t, 7>;

Patron patron(int digito, int tipo) { // tipo 0 = L, 1 = G, 2 = R
  Patron p{};
  for (int i = 0; i < 7; i++) {
    const int l = kL[digito][i] - '0';
    if (tipo == 0) p[i] = (uint8_t)l;
    else if (tipo == 2) p[i] = (uint8_t)(1 - l);
    else p[i] = (uint8_t)(1 - (kL[digito][6 - i] - '0')); // G = R invertido en orden
  }
  return p;
}

// Funcion de distribucion normal, por tabla (se llama millones de veces).
struct Fi {
  std::array<float, 1601> v;
  Fi() {
    for (int i = 0; i <= 1600; i++) v[i] = 0.5f * std::erfc(-(-8.0f + i * 0.01f) / std::sqrt(2.0f));
  }
  float operator()(float x) const {
    if (x <= -8) return 0;
    if (x >= 8) return 1;
    const float f = (x + 8) * 100;
    const int i = std::min((int)f, 1599);
    const float t = f - i;
    return v[i] + (v[i + 1] - v[i]) * t;
  }
};
const Fi fi;

// Desenfoque: movimiento (caja de ancho [caja]) combinado con desenfoque de
// foco y del pixel (gaussiano [sigma]). Se guarda su respuesta a un borde.
struct Nucleo {
  static constexpr float kPaso = 0.05f;
  float r = 1;
  float caja = 0, sigma = 1;
  std::vector<float> e;
  Nucleo() = default;
  Nucleo(float caja, float sigma) : caja(caja), sigma(sigma) {
    r = caja / 2 + 4 * sigma + 0.1f;
    const int n = (int)(2 * r / kPaso) + 2;
    e.resize(n);
    constexpr int kMuestras = 24;
    for (int i = 0; i < n; i++) {
      const float d = -r + i * kPaso;
      if (caja <= 0) {
        e[i] = fi(d / sigma);
        continue;
      }
      float acum = 0;
      for (int k = 0; k < kMuestras; k++) {
        const float u = -caja / 2 + caja * (k + 0.5f) / kMuestras;
        acum += fi((d - u) / sigma);
      }
      e[i] = acum / kMuestras;
    }
  }
  float operator()(float d) const {
    if (d <= -r) return 0;
    if (d >= r) return 1;
    const float f = (d + r) / kPaso;
    const int i = std::min((int)f, (int)e.size() - 2);
    const float t = f - i;
    return e[i] + (e[i + 1] - e[i]) * t;
  }
};

// Modulo -> pixel, lineal por tramos entre anclas (las guardas): tolera
// perspectiva y etiquetas algo curvas.
struct Mapa {
  float k[3], x[3];
  float operator()(float m) const {
    const int i = m < k[1] ? 0 : 1;
    return x[i] + (m - k[i]) * (x[i + 1] - x[i]) / (k[i + 1] - k[i]);
  }
};

struct Estructura {
  int modulos, izq, der, centro, fin; // centro/fin: primer modulo de esas guardas
  int inicioIzq(int i) const { return 3 + 7 * i; }
  int inicioDer(int i) const { return centro + 5 + 7 * i; }
};
const Estructura kEan13{95, 6, 6, 45, 92};
const Estructura kEan8{67, 4, 4, 31, 64};

// Ajuste lineal y = a + b*t: devuelve 1 - r^2 (0 = calza perfecto) y el signo
// de b en [b]. Sin variacion: 1.
float ajuste(const float* y, const float* t, int n, float* a = nullptr, float* b = nullptr) {
  double st = 0, sy = 0, stt = 0, syy = 0, sty = 0;
  for (int i = 0; i < n; i++) {
    st += t[i];
    sy += y[i];
    stt += (double)t[i] * t[i];
    syy += (double)y[i] * y[i];
    sty += (double)t[i] * y[i];
  }
  const double vt = stt - st * st / n, vy = syy - sy * sy / n, c = sty - st * sy / n;
  if (vt < 1e-6 || vy < 1e-6) return 1;
  const double pb = c / vt;
  if (b) *b = (float)pb;
  if (a) *a = (float)((sy - pb * st) / n);
  return (float)(1 - c * c / (vt * vy));
}

struct Perfil {
  std::vector<float> p;
  int n() const { return (int)p.size(); }
};

// Dibujo esperado (0..1, 1 = barra) en los pixeles [x0, x1) para los modulos
// [k0, k0 + bits.size()) con desenfoque [sigma] (pixeles).
void dibujar(const Mapa& mapa, float desplazamiento, int k0, const float* bits, int nbits, const Nucleo& nu, int x0,
             int x1, float* salida) {
  float bordes[24];
  for (int j = 0; j <= nbits; j++) bordes[j] = mapa((float)(k0 + j)) + desplazamiento;
  for (int x = x0; x < x1; x++) {
    const float c = x + 0.5f;
    float v = 0;
    float anterior = nu(bordes[0] - c);
    for (int j = 0; j < nbits; j++) {
      const float siguiente = nu(bordes[j + 1] - c);
      if (bits[j] != 0) v += bits[j] * (siguiente - anterior);
      anterior = siguiente;
    }
    salida[x - x0] = v;
  }
}

// Costo de un tramo de modulos con bits conocidos.
float costoTramo(const Perfil& pf, const Mapa& mapa, float desp, int k0, const float* bits, int nbits, const Nucleo& sigma,
                 float* a = nullptr, float* b = nullptr) {
  const int x0 = std::max(0, (int)std::floor(mapa((float)k0) + desp));
  const int x1 = std::min(pf.n(), (int)std::ceil(mapa((float)(k0 + nbits)) + desp));
  const int n = x1 - x0;
  if (n < nbits) return 1;
  float t[512];
  if (n > 512) return 1;
  dibujar(mapa, desp, k0, bits, nbits, sigma, x0, x1, t);
  return ajuste(&pf.p[x0], t, n, a, b);
}

struct Guardas {
  Mapa mapa;
  const Nucleo* sigma = nullptr;
  float costo = 3;
  float a = 0, b = 0; // nivel claro y contraste (b < 0: barras oscuras)
  // Nivel claro y contraste en cada guarda (inicio, centro, fin): entre
  // ellas se interpola (la luz cambia a lo largo de la etiqueta).
  float ga[3] = {}, gb[3] = {};
  float claro(float k) const { return interpolar(ga, k); }
  float contraste(float k) const { return interpolar(gb, k); }
  // Solo con las guardas de los extremos: incluyen la zona blanca, asi el
  // contraste queda bien medido aunque el desenfoque borre el 101 (la del
  // centro no tiene zona blanca).
  float interpolar(const float* v, float k) const {
    if (gb[0] >= 0) return v[2];
    if (gb[2] >= 0) return v[0];
    const float t = std::clamp(k / (float)mapa.k[2], 0.0f, 1.0f);
    return v[0] + (v[2] - v[0]) * t;
  }
};

// Costo con el nivel y el contraste de las guardas (no se ajustan por
// tramo: un digito equivocado no puede "acomodarse" cambiando el contraste).
// Error cuadratico medio relativo al contraste.
float costoFijo(const Perfil& pf, const Guardas& g, float desp, int k0, const float* bits, int nbits) {
  const int x0 = std::max(0, (int)std::floor(g.mapa((float)k0) + desp));
  const int x1 = std::min(pf.n(), (int)std::ceil(g.mapa((float)(k0 + nbits)) + desp));
  const int n = x1 - x0;
  if (n < nbits || n > 512) return 1;
  float t[512];
  dibujar(g.mapa, desp, k0, bits, nbits, *g.sigma, x0, x1, t);
  const float km = k0 + nbits * 0.5f;
  const float a = g.claro(km), b = g.contraste(km);
  if (b >= 0) return 1;
  double e = 0;
  for (int i = 0; i < n; i++) {
    const double r = pf.p[x0 + i] - (a + b * t[i]);
    e += r * r;
  }
  return (float)(e / n / ((double)b * b));
}

// Las tres guardas (con lo que se sabe de sus vecinos: primer/ultimo modulo
// de cada digito y la zona blanca) ubican el codigo, el ancho de modulo y el
// desenfoque.
Guardas buscarGuardas(const Perfil& pf, const Estructura& e, float izq, float der, const std::vector<Nucleo>& nucleos) {
  // inicio: zona blanca(3) 101 + primer modulo de digito izquierdo (0)
  static const float kIni[7] = {0, 0, 0, 1, 0, 1, 0};
  // centro: ultimo de izquierdo (1) 01010 primero de derecho (1)
  static const float kCen[7] = {1, 0, 1, 0, 1, 0, 1};
  // fin: ultimo de derecho (0) 101 zona blanca(3)
  static const float kFin[7] = {0, 1, 0, 1, 0, 0, 0};
  const float m0 = (der - izq) / e.modulos;
  Guardas mejor;
  auto probar = [&](const Nucleo& nu, float f, float o) {
    const float m = m0 * f;
    const float s = izq + o * m0;
    const Mapa mapa{{0.0f, (float)e.centro, (float)e.modulos}, {s, s + e.centro * m, s + e.modulos * m}};
    float a, b;
    const float c1 = costoTramo(pf, mapa, 0, -3, kIni, 7, nu, &a, &b);
    if (c1 > mejor.costo) return;
    const float c2 = costoTramo(pf, mapa, 0, e.centro - 1, kCen, 7, nu);
    if (c1 + c2 > mejor.costo) return;
    const float c3 = costoTramo(pf, mapa, 0, e.fin - 1, kFin, 7, nu);
    const float c = c1 + c2 + c3;
    if (c < mejor.costo) {
      mejor.costo = c;
      mejor.mapa = mapa;
      mejor.sigma = &nu;
      mejor.a = a;
      mejor.b = b;
    }
  };
  // Grueso y despues fino alrededor de lo mejor.
  float mf = 1, mo = 0;
  for (const auto& nu : nucleos)
    for (float f = 0.9f; f <= 1.1001f; f += 0.025f)
      for (float o = -2.5f; o <= 2.5001f; o += 0.25f) probar(nu, f, o);
  if (mejor.costo >= 3) return mejor;
  mf = (mejor.mapa.x[2] - mejor.mapa.x[0]) / (e.modulos * m0);
  mo = (mejor.mapa.x[0] - izq) / m0;
  for (const auto& nu : nucleos)
    for (float f = mf - 0.02f; f <= mf + 0.0201f; f += 0.005f)
      for (float o = mo - 0.3f; o <= mo + 0.3001f; o += 0.05f) probar(nu, f, o);
  // Ajuste fino de cada guarda por separado (perspectiva).
  const float m = (mejor.mapa.x[2] - mejor.mapa.x[0]) / e.modulos;
  const float* pat[3] = {kIni, kCen, kFin};
  const int k0[3] = {-3, e.centro - 1, e.fin - 1};
  float nuevos[3];
  for (int g = 0; g < 3; g++) {
    float mejorC = 2, mejorD = 0;
    for (float d = -0.4f; d <= 0.4001f; d += 0.04f) {
      const float c = costoTramo(pf, mejor.mapa, d * m, k0[g], pat[g], 7, *mejor.sigma);
      if (c < mejorC) {
        mejorC = c;
        mejorD = d;
      }
    }
    nuevos[g] = mejor.mapa.x[g] + mejorD * m;
  }
  for (int g = 0; g < 3; g++) mejor.mapa.x[g] = nuevos[g];
  for (int g = 0; g < 3; g++) costoTramo(pf, mejor.mapa, 0, k0[g], pat[g], 7, *mejor.sigma, &mejor.ga[g], &mejor.gb[g]);
  return mejor;
}

struct Candidato {
  int digito, tipo; // tipo 0 L, 1 G, 2 R
  float costo;
};

// Costo de cada digito posible en la posicion que empieza en el modulo [k0].
// [antes]/[despues]: 2 modulos vecinos (0.5 = no se sabe).
void costosDigito(const Perfil& pf, const Guardas& g, int k0, const int* tipos, int ntipos, const float* antes,
                  const float* despues, std::vector<Candidato>& salida) {
  const float m = (g.mapa.x[2] - g.mapa.x[0]) / (g.mapa.k[2] - g.mapa.k[0]);
  salida.clear();
  for (int ti = 0; ti < ntipos; ti++) {
    for (int d = 0; d < 10; d++) {
      const Patron p = patron(d, tipos[ti]);
      float bits[11] = {antes[0], antes[1]};
      for (int i = 0; i < 7; i++) bits[2 + i] = p[i];
      bits[9] = despues[0];
      bits[10] = despues[1];
      float mejor = 1e9f;
      for (float desp : {-0.3f, -0.15f, 0.0f, 0.15f, 0.3f})
        mejor = std::min(mejor, costoFijo(pf, g, desp * m, k0 - 2, bits, 11));
      salida.push_back({d, tipos[ti], mejor});
    }
  }
}

struct Solucion {
  std::vector<int> digitos; // todos, con el primero (EAN-13) y el verificador
  float costo = 1e9f;
  std::vector<int> elegidos; // indice de candidato por posicion
};

// Digitos que juntos cumplen paridad y verificador con el menor costo.
// [prohibido]: posicion y candidato que no se pueden usar (para medir el margen).
Solucion elegir(const std::vector<std::vector<Candidato>>& pos, bool ean13, int prohibidaPos = -1,
                int prohibidoDigito = -1) {
  const int np = (int)pos.size();
  const int estados = ean13 ? 640 : 10;
  std::vector<std::vector<float>> costo(np + 1, std::vector<float>(estados, 1e9f));
  std::vector<std::vector<std::pair<int, int>>> atras(np + 1, std::vector<std::pair<int, int>>(estados, {-1, -1}));
  costo[0][0] = 0;
  for (int i = 0; i < np; i++) {
    // Peso del digito en el verificador.
    const int indice = ean13 ? i + 1 : i;
    const int peso = ean13 ? (indice % 2 == 1 ? 3 : 1) : (indice % 2 == 0 ? 3 : 1);
    for (int s = 0; s < estados; s++) {
      if (costo[i][s] >= 1e9f) continue;
      const int mod = s % 10, par = s / 10;
      for (int c = 0; c < (int)pos[i].size(); c++) {
        const auto& k = pos[i][c];
        if (i == prohibidaPos && k.digito == prohibidoDigito) continue;
        int npar = par;
        if (ean13 && i < 6) npar = par | ((k.tipo == 1 ? 1 : 0) << (5 - i));
        const int ns = ((mod + peso * k.digito) % 10) + 10 * npar;
        const float nc = costo[i][s] + k.costo;
        if (nc < costo[i + 1][ns]) {
          costo[i + 1][ns] = nc;
          atras[i + 1][ns] = {s, c};
        }
      }
    }
  }
  Solucion mejor;
  int final = -1, primero = -1;
  for (int s = 0; s < estados; s++) {
    if (costo[np][s] >= mejor.costo) continue;
    const int mod = s % 10, par = s / 10;
    int d0 = 0;
    if (ean13) {
      d0 = -1;
      for (int d = 0; d < 10; d++)
        if (kParidad[d] == par) d0 = d;
      if (d0 < 0 || (mod + d0) % 10 != 0) continue;
    } else if (mod != 0) {
      continue;
    }
    mejor.costo = costo[np][s];
    final = s;
    primero = d0;
  }
  if (final < 0) return mejor;
  mejor.elegidos.assign(np, 0);
  std::vector<int> ds(np);
  for (int i = np, s = final; i > 0; i--) {
    const auto [ps, c] = atras[i][s];
    mejor.elegidos[i - 1] = c;
    ds[i - 1] = pos[i - 1][c].digito;
    s = ps;
  }
  if (ean13) mejor.digitos.push_back(primero);
  mejor.digitos.insert(mejor.digitos.end(), ds.begin(), ds.end());
  return mejor;
}

bool decodificar(const Perfil& pf, const Estructura& e, bool ean13, const Guardas& g, Resultado& r, float& costoTotal);

std::vector<Nucleo> nucleosPara(float m0);

bool leerEstructura(const Perfil& pf, const Estructura& e, bool ean13, float izq, float der, Resultado& r) {
  const float m0 = (der - izq) / e.modulos;
  if (m0 < 1.0f || m0 > 30) return false;
  const auto nucleos = nucleosPara(m0);
  Guardas g = buscarGuardas(pf, e, izq, der, nucleos);
  DEP("  guardas costo=%.3f b=%.1f caja=%.1f sigma=%.2f m0=%.2f x=[%.1f %.1f %.1f]\n", g.costo, g.b,
      g.sigma ? g.sigma->caja : -1, g.sigma ? g.sigma->sigma : -1, m0, g.mapa.x[0], g.mapa.x[1], g.mapa.x[2]);
  if (g.costo > 1.2f || g.b >= 0) return false;
  const float m = (g.mapa.x[2] - g.mapa.x[0]) / e.modulos;
  const float mIzq = (g.mapa.x[1] - g.mapa.x[0]) / e.centro, mDer = (g.mapa.x[2] - g.mapa.x[1]) / (e.modulos - e.centro);
  if (std::abs(mIzq - mDer) > 0.15f * m) return false;

  // Las guardas son simetricas: sirven para los dos sentidos de lectura.
  Perfil reves = pf;
  std::reverse(reves.p.begin(), reves.p.end());
  const float n = (float)pf.n();
  Guardas gr = g;
  gr.mapa = Mapa{{0.0f, (float)(e.modulos - e.centro), (float)e.modulos}, {n - g.mapa.x[2], n - g.mapa.x[1], n - g.mapa.x[0]}};
  std::swap(gr.ga[0], gr.ga[2]);
  std::swap(gr.gb[0], gr.gb[2]);
  Resultado r1, r2;
  float c1 = 0, c2 = 0;
  const bool ok1 = decodificar(pf, e, ean13, g, r1, c1);
  const bool ok2 = decodificar(reves, e, ean13, gr, r2, c2);
  if (!ok1 && !ok2) return false;
  if (ok1 && (!ok2 || c1 <= c2)) {
    r = r1;
  } else {
    r = r2;
    r.x0 = n - r2.x1;
    r.x1 = n - r2.x0;
  }
  return true;
}

bool decodificar(const Perfil& pf, const Estructura& e, bool ean13, const Guardas& g, Resultado& r, float& costoTotal) {

  // Zona blanca a los costados (si entra en el recorte): evita leer un
  // pedazo de otro codigo.
  for (int lado = 0; lado < 2; lado++) {
    const float desde = lado == 0 ? g.mapa(-7) : g.mapa((float)e.modulos + 1);
    const float hasta = lado == 0 ? g.mapa(-1) : g.mapa((float)e.modulos + 7);
    const int x0 = std::max(0, (int)desde), x1 = std::min(pf.n(), (int)hasta);
    if (x1 - x0 < 2) continue;
    float s = 0;
    for (int x = x0; x < x1; x++) s += pf.p[x];
    if (s / (x1 - x0) < g.a + 0.35f * g.b) return false;
  }

  const int np = e.izq + e.der;
  std::vector<std::vector<Candidato>> pos(np);
  const int tiposIzq13[2] = {0, 1}, tiposIzq8[1] = {0}, tiposDer[1] = {2};
  const float nose[2] = {0.5f, 0.5f};
  // Vecinos conocidos: digito izquierdo empieza en 0 y termina en 1; derecho al reves.
  const float antesIzq[2] = {0.5f, 1}, despuesIzq[2] = {0, 0.5f};
  const float antesDer[2] = {0.5f, 0}, despuesDer[2] = {1, 0.5f};
  (void)nose;
  Solucion sol;
  for (int vuelta = 0; vuelta < 2; vuelta++) {
    for (int i = 0; i < np; i++) {
      const bool izqda = i < e.izq;
      const int k0 = izqda ? e.inicioIzq(i) : e.inicioDer(i - e.izq);
      float antes[2], despues[2];
      std::copy(izqda ? antesIzq : antesDer, (izqda ? antesIzq : antesDer) + 2, antes);
      std::copy(izqda ? despuesIzq : despuesDer, (izqda ? despuesIzq : despuesDer) + 2, despues);
      if (vuelta == 1) {
        // Segunda vuelta: los vecinos son los digitos ya elegidos.
        auto modulo = [&](int k) -> float {
          if (k < 0 || k >= e.modulos) return 0;
          if (k < 3 || (k >= e.centro && k < e.centro + 5) || k >= e.fin) {
            static const int gi[3] = {1, 0, 1};
            static const int gc[5] = {0, 1, 0, 1, 0};
            if (k < 3) return (float)gi[k];
            if (k >= e.fin) return (float)gi[k - e.fin];
            return (float)gc[k - e.centro];
          }
          const bool enIzq = k < e.centro;
          const int j = enIzq ? (k - 3) / 7 : e.izq + (k - e.centro - 5) / 7;
          const int dentro = enIzq ? (k - 3) % 7 : (k - e.centro - 5) % 7;
          const auto& c = pos[j][sol.elegidos[j]];
          return (float)patron(c.digito, c.tipo)[dentro];
        };
        antes[0] = modulo(k0 - 2);
        antes[1] = modulo(k0 - 1);
        despues[0] = modulo(k0 + 7);
        despues[1] = modulo(k0 + 8);
      }
      if (izqda) costosDigito(pf, g, k0, ean13 ? tiposIzq13 : tiposIzq8, ean13 ? 2 : 1, antes, despues, pos[i]);
      else costosDigito(pf, g, k0, tiposDer, 1, antes, despues, pos[i]);
    }
    sol = elegir(pos, ean13);
    if (sol.digitos.empty()) return false;
  }

  // Claridad: cada digito elegido tiene que ser tambien el mejor en su
  // posicion por si solo, el dibujo tiene que calzar, y cualquier otra
  // combinacion valida tiene que costar bastante mas (margen relativo).
  // Umbrales medidos en un banco con 400 casos movidos o borrosos y 3000
  // perfiles sin EAN (rayas, texto, otros 1D): 0 lecturas falsas, y el
  // margen exigido es 2,5 veces el mayor que dio un perfil sin EAN.
  float maximo = 0;
  int distintos = 0;
  for (int i = 0; i < np; i++) {
    float minimo = 1;
    for (const auto& c : pos[i]) minimo = std::min(minimo, c.costo);
    const float elegido = pos[i][sol.elegidos[i]].costo;
    maximo = std::max(maximo, elegido);
    if (elegido > minimo + 0.02f) distintos++;
  }
  const float promedio = sol.costo / np;
  {
    std::string t;
    for (int d : sol.digitos) t += (char)('0' + d);
    DEP("  digitos %s distintos=%d maximo=%.3f promedio=%.3f\n", t.c_str(), distintos, maximo, promedio);
  }
  if (distintos > 0 || maximo > 0.08f || promedio > 0.05f) return false;
  float margen = 1e9f;
  for (int i = 0; i < np; i++) {
    const int d = sol.digitos[ean13 ? i + 1 : i];
    const Solucion otra = elegir(pos, ean13, i, d);
    margen = std::min(margen, otra.costo - sol.costo);
  }
  {
    std::string t;
    for (int d : sol.digitos) t += (char)('0' + d);
    DEP("MET %s %d %.4f %.4f %.4f %.4f\n", t.c_str(), distintos, maximo, promedio, margen, g.costo);
  }
  if (margen < 0.1f * sol.costo) return false;

  r.texto.clear();
  for (int d : sol.digitos) r.texto += (char)('0' + d);
  r.ean8 = !ean13;
  r.x0 = g.mapa.x[0];
  r.x1 = g.mapa.x[2];
  r.calidad = 1 - promedio;
  costoTotal = sol.costo;
  return true;
}

// Extremos del codigo: la zona mas larga con muchos bordes.
bool extension(const Perfil& pf, float& izq, float& der) {
  const int n = pf.n();
  if (n < 40) return false;
  std::vector<float> g(n, 0), s(n, 0);
  for (int x = 1; x + 1 < n; x++) g[x] = std::abs(pf.p[x + 1] - pf.p[x - 1]);
  const int v = std::max(2, n / 80);
  float acum = 0, maximo = 0;
  for (int x = 0; x < n; x++) {
    acum += g[x];
    if (x >= 2 * v + 1) acum -= g[x - 2 * v - 1];
    if (x >= v) s[x - v] = acum;
  }
  for (float x : s) maximo = std::max(maximo, x);
  if (maximo <= 0) return false;
  const float umbral = 0.2f * maximo;
  const int hueco = std::max(3, n / 30);
  int mejorI = -1, mejorD = -1, i = -1, ultimo = -1;
  for (int x = 0; x <= n; x++) {
    const bool activo = x < n && s[x] > umbral;
    if (activo) {
      if (i < 0 || x - ultimo > hueco) i = x;
      ultimo = x;
      if (ultimo - i > mejorD - mejorI) {
        mejorI = i;
        mejorD = ultimo;
      }
    }
  }
  if (mejorI < 0 || mejorD - mejorI < n / 5) return false;
  izq = (float)mejorI;
  der = (float)mejorD;
  return true;
}

// Perfil promedio de las filas [y0, y1) y extremos del codigo, con las
// barras como lo oscuro.
bool perfilDe(const prep::Gris& img, int y0, int y1, Perfil& pf, float& izq, float& der) {
  pf.p.assign(img.ancho, 0);
  for (int y = y0; y < y1; y++)
    for (int x = 0; x < img.ancho; x++) pf.p[x] += img.px[(size_t)y * img.ancho + x];
  for (auto& v : pf.p) v /= (float)(y1 - y0);
  if (!extension(pf, izq, der)) return false;
  // Si el codigo es mas claro que lo que lo rodea (claro sobre oscuro), se invierte.
  const float margen = 0.15f * (der - izq);
  float dentro = 0, fuera = 0;
  int nd = 0, nf = 0;
  for (int x = 0; x < pf.n(); x++) {
    if (x >= izq && x <= der) {
      dentro += pf.p[x];
      nd++;
    } else if (x >= izq - margen && x <= der + margen) {
      fuera += pf.p[x];
      nf++;
    }
  }
  if (nd > 0 && nf > 0 && dentro / nd > fuera / nf)
    for (auto& v : pf.p) v = 255 - v;
  return true;
}

std::vector<Nucleo> nucleosPara(float m0) {
  // Desenfoques a probar, relativos al ancho de modulo: de foco (gaussiano)
  // y de movimiento (caja), mas el del pixel.
  std::vector<Nucleo> nucleos;
  for (float sr : {0.3f, 0.6f, 0.95f, 1.4f}) nucleos.emplace_back(0.0f, std::sqrt(sr * m0 * sr * m0 + 0.09f));
  for (float cr : {1.0f, 1.5f, 2.0f, 2.5f, 3.0f}) nucleos.emplace_back(cr * m0, std::sqrt(0.3f * m0 * 0.3f * m0 + 0.09f));
  return nucleos;
}

// Cuantos digitos de [d] (todos, con el primero si es EAN-13) calzan claramente
// peor que el mejor digito posible en su lugar.
int digitosMalos(const Perfil& pf, const Estructura& e, bool ean13, const Guardas& g, const std::vector<int>& d) {
  const int tiposIzq13[2] = {0, 1}, tiposIzq8[1] = {0}, tiposDer[1] = {2};
  const float antesIzq[2] = {0.5f, 1}, despuesIzq[2] = {0, 0.5f};
  const float antesDer[2] = {0.5f, 0}, despuesDer[2] = {1, 0.5f};
  std::vector<Candidato> c;
  int malos = 0;
  const int np = e.izq + e.der;
  for (int i = 0; i < np; i++) {
    const bool izqda = i < e.izq;
    const int k0 = izqda ? e.inicioIzq(i) : e.inicioDer(i - e.izq);
    if (izqda) costosDigito(pf, g, k0, ean13 ? tiposIzq13 : tiposIzq8, ean13 ? 2 : 1, antesIzq, despuesIzq, c);
    else costosDigito(pf, g, k0, tiposDer, 1, antesDer, despuesDer, c);
    const int digito = d[ean13 ? i + 1 : i];
    const int tipo = !izqda ? 2 : (ean13 ? (kParidad[d[0]] >> (5 - i)) & 1 : 0);
    float minimo = 1e9f, propio = 1e9f;
    for (const auto& k : c) {
      minimo = std::min(minimo, k.costo);
      if (k.digito == digito && k.tipo == tipo) propio = k.costo;
    }
    if (propio > 1.5f * minimo + 0.003f) malos++;
  }
  return malos;
}

} // namespace

int verificarEan(const prep::Gris& img, const std::string& texto) {
  const bool ean13 = texto.size() == 13;
  if ((!ean13 && texto.size() != 8) || img.ancho < 60 || img.alto < 8) return 0;
  std::vector<int> d;
  for (char ch : texto) {
    if (ch < '0' || ch > '9') return 0;
    d.push_back(ch - '0');
  }
  const Estructura& e = ean13 ? kEan13 : kEan8;
  Perfil pf;
  float izq, der;
  if (!perfilDe(img, (int)(img.alto * 0.35f), std::max((int)(img.alto * 0.35f) + 1, (int)(img.alto * 0.65f)), pf, izq,
                der)) {
    DEP("verificar %s: sin perfil\n", texto.c_str());
    return 0;
  }
  const float m0 = (der - izq) / e.modulos;
  DEP("verificar %s: ancho=%d izq=%.1f der=%.1f m0=%.2f\n", texto.c_str(), img.ancho, izq, der, m0);
  if (m0 < 1.0f || m0 > 30) return 0;
  const auto nucleos = nucleosPara(m0);
  const Guardas g = buscarGuardas(pf, e, izq, der, nucleos);
  DEP("verificar %s: guardas %.3f b=%.1f\n", texto.c_str(), g.costo, g.b);
  if (g.costo > 1.2f || g.b >= 0) return 0;
  Perfil reves = pf;
  std::reverse(reves.p.begin(), reves.p.end());
  const float n = (float)pf.n();
  Guardas gr = g;
  gr.mapa = Mapa{{0.0f, (float)(e.modulos - e.centro), (float)e.modulos}, {n - g.mapa.x[2], n - g.mapa.x[1], n - g.mapa.x[0]}};
  std::swap(gr.ga[0], gr.ga[2]);
  std::swap(gr.gb[0], gr.gb[2]);
  const int malos = std::min(digitosMalos(pf, e, ean13, g, d), digitosMalos(reves, e, ean13, gr, d));
  DEP("verificar %s malos=%d\n", texto.c_str(), malos);
  if (malos >= 4) return -1;
  return malos <= 1 ? 1 : 0;
}

bool leerEan(const prep::Gris& img, bool ean13, bool ean8, Resultado& r) {
  if (img.ancho < 60 || img.alto < 8) return false;
  // Bandas de filas: el centro, y si no, mas alto (codigos cortos o torcidos).
  const float bandas[2][2] = {{0.35f, 0.65f}, {0.2f, 0.8f}};
  for (const auto& banda : bandas) {
    const int y0 = (int)(img.alto * banda[0]), y1 = std::max(y0 + 1, (int)(img.alto * banda[1]));
    Perfil pf;
    float izq, der;
    if (!perfilDe(img, y0, y1, pf, izq, der)) continue;
    if ((ean13 && leerEstructura(pf, kEan13, true, izq, der, r)) || (ean8 && leerEstructura(pf, kEan8, false, izq, der, r))) {
      r.y0 = (float)y0;
      r.y1 = (float)y1;
      return true;
    }
  }
  return false;
}

} // namespace gris
