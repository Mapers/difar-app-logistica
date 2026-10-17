#include "motor_lector.h"
#include "preparar.h"
#include "ean_gris.h"
#include "red_ean.h"
#include "red_restaurar.h"
#ifdef ML_CON_OPENCV
#include "detector.h"
#endif

#include "ReadBarcode.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace ZXing;

namespace {

using Reloj = std::chrono::steady_clock;

// Hilos para los pasos dificiles (ml_configurar). <= 1: uno tras otro,
// repartidos entre cuadros con [ronda].
std::atomic<int> gHilos{0}; // 0 = segun los nucleos del telefono

std::atomic<bool> gDetector{true};

// Nitidez promedio de los ultimos cuadros (x16) y cuantos cuadros seguidos se
// aplazaron los pasos dificiles por venir borrosos: se gastan en un cuadro
// nitido (en el telefono la mayoria salia movida y los pasos caros no leian).
std::atomic<int> gNitidezProm{0};
std::atomic<int> gAplazados{0};

int hilosEnUso() {
  const int h = gHilos.load();
  if (h > 0) return h;
  return (int)std::clamp(std::thread::hardware_concurrency(), 1u, 8u);
}

struct Formato {
  int32_t bit;
  BarcodeFormat zx;
};

// Simbologias de zxing por cada bit de la mascara.
const Formato kFormatos[] = {
    {ML_EAN13, BarcodeFormat::EAN13},     {ML_EAN8, BarcodeFormat::EAN8},
    {ML_UPCA, BarcodeFormat::UPCA},       {ML_UPCE, BarcodeFormat::UPCE},
    {ML_CODE128, BarcodeFormat::Code128}, {ML_CODE39, BarcodeFormat::Code39},
    {ML_CODE93, BarcodeFormat::Code93},   {ML_ITF, BarcodeFormat::ITF},
    {ML_CODABAR, BarcodeFormat::Codabar}, {ML_DATABAR, BarcodeFormat::DataBar},
    {ML_QR, BarcodeFormat::QRCode},       {ML_DATAMATRIX, BarcodeFormat::DataMatrix},
    {ML_PDF417, BarcodeFormat::PDF417},   {ML_AZTEC, BarcodeFormat::Aztec},
    {ML_MICROQR, BarcodeFormat::MicroQRCode},
};

BarcodeFormats aFormatosZx(int32_t mascara) {
  if (mascara == 0) return BarcodeFormat::AllReadable;
  std::vector<BarcodeFormat> lista;
  for (const auto& f : kFormatos)
    if (mascara & f.bit) lista.push_back(f.zx);
  return BarcodeFormats(std::move(lista));
}

int32_t aBit(BarcodeFormat f) {
  // Variantes (ITF-14, EAN con add-on, DataBar Expanded...) van a su simbologia.
  for (const auto& k : kFormatos)
    if (k.zx == f || k.zx == Symbology(f)) return k.bit;
  return 0;
}

// Formatos sin largo fijo ni digito de control obligatorio: un pedazo del
// codigo tambien "decodifica" (p. ej. ITF "177501" de un ITF-14). Se exige un
// largo minimo; ademas la app pide verlos igual en 2 cuadros seguidos.
bool confiable(const Barcode& b) {
  const auto largo = b.text().size();
  switch (Symbology(b.format())) {
  case BarcodeFormat::ITF: return largo >= 10; // logistica: ITF-14
  case BarcodeFormat::Code39:
  case BarcodeFormat::Code93:
  case BarcodeFormat::Codabar: return largo >= 4;
  default: return true;
  }
}

// Lleva un punto de la imagen preparada a la imagen de entrada:
// X = a*x + b*y + tx ; Y = c*x + d*y + ty.
struct Afin {
  float a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;
  static Afin desplazar(float dx, float dy, float escala = 1) { return {escala, 0, 0, escala, dx, dy}; }
};

struct Lectura {
  std::string texto;
  BarcodeFormat formato = BarcodeFormat::None;
  std::array<PointF, 4> pos{}; // esquinas en la imagen del paso
  int paso = 0;
  Afin aEntrada;
  bool invertido = false;
  float cx = 0, cy = 0, largo = 0; // centro y lado mayor en la imagen de entrada

  Lectura() = default;
  Lectura(const Barcode& b, int paso, Afin t, bool inv)
      : texto(b.text()), formato(b.format()), paso(paso), aEntrada(t), invertido(inv || b.isInverted()) {
    for (int i = 0; i < 4; i++) pos[i] = PointF(b.position()[i]);
  }
};

// Centro y lado mayor del codigo en la imagen de entrada.
void medirEnEntrada(Lectura& l) {
  const auto& pos = l.pos;
  float xs[4], ys[4];
  for (int i = 0; i < 4; i++) {
    xs[i] = l.aEntrada.a * pos[i].x + l.aEntrada.b * pos[i].y + l.aEntrada.tx;
    ys[i] = l.aEntrada.c * pos[i].x + l.aEntrada.d * pos[i].y + l.aEntrada.ty;
  }
  l.cx = (xs[0] + xs[1] + xs[2] + xs[3]) / 4;
  l.cy = (ys[0] + ys[1] + ys[2] + ys[3]) / 4;
  l.largo = 0;
  for (int i = 0; i < 4; i++)
    l.largo = std::max(l.largo, std::hypot(xs[i] - xs[(i + 1) % 4], ys[i] - ys[(i + 1) % 4]));
}

struct Lector {
  BarcodeFormats formatos;
  int32_t mascara = 0; // formatos pedidos (ML_*, 0 = todos)
  bool multiple = false; // todos los codigos (ML_MODO_TODOS)
  std::vector<Lectura> leidos;
  // Los pasos corren en paralelo: lo compartido va protegido.
  std::mutex cerrojo;
  std::atomic<bool> hayUno{false};
  std::atomic<int> cuantos{0}; // codigos distintos leidos hasta ahora
  std::atomic<int> ilegibles{0};

  // [preparada]: la imagen fue procesada (contraste, normalizacion,
  // ampliacion...). Ahi es donde aparecen lecturas falsas que igual pasan el
  // digito verificador (en el telefono: 1111130013606, 1551130053606 del
  // mismo codigo), asi que se exige que mas lineas de barrido den lo mismo.
  ReaderOptions opciones(bool esfuerzo, bool preparada = false) const {
    ReaderOptions o;
    o.setMinLineCount(preparada ? 3 : 2);
    o.setFormats(formatos);
    o.setTextMode(TextMode::Plain);
    o.setTryRotate(true);
    o.setTryDownscale(true);
    o.setTryHarder(esfuerzo);
    o.setTryInvert(esfuerzo); // solo afecta a 2D; el 1D invertido tiene su propio paso
    o.setMaxNumberOfSymbols(multiple ? 255 : 1);
    return o;
  }

  // [errores]: tambien devuelve simbolos encontrados que fallan la
  // verificacion (se cuentan como ilegibles: hay codigo pero esta danado).
  // Devuelve cuantos codigos nuevos agrego.
  int leer(const ImageView& img, ReaderOptions o, int paso, Afin t = {}, bool invertido = false,
           bool errores = false, const std::function<bool(const Barcode&)>& validar = nullptr) {
    if (listo()) return 0;
    int nuevos = 0;
    o.setReturnErrors(errores);
    auto encontrados = ReadBarcodes(img, o);
    std::lock_guard<std::mutex> l(cerrojo);
    for (auto& b : encontrados) {
      if (!b.isValid()) {
        if (b.error().type() == Error::Type::Checksum) ilegibles++;
        continue;
      }
      if (!confiable(b)) continue;
      if (validar && !validar(b)) continue;
      nuevos += agregarSinCerrojo(Lectura(b, paso, t, invertido));
    }
    return nuevos;
  }

  // Lectura de otro decodificador (el de tonos de gris).
  int agregar(Lectura nueva) {
    std::lock_guard<std::mutex> l(cerrojo);
    return agregarSinCerrojo(std::move(nueva));
  }

  int agregarSinCerrojo(Lectura nueva) {
    // Cada codigo fisico cuenta: dos cajas con el mismo EAN son dos lecturas.
    // Es "el mismo" solo si ademas esta en el mismo lugar (lo leyeron dos pasos).
    medirEnEntrada(nueva);
    const bool repetido = std::any_of(leidos.begin(), leidos.end(), [&](const Lectura& l) {
      if (l.texto != nueva.texto || Symbology(l.formato) != Symbology(nueva.formato)) return false;
      const float radio = 0.5f * std::max(l.largo, nueva.largo);
      return std::hypot(l.cx - nueva.cx, l.cy - nueva.cy) < std::max(radio, 8.0f);
    });
    if (repetido) return 0;
    leidos.push_back(std::move(nueva));
    hayUno = true;
    cuantos++;
    return 1;
  }

  bool listo() const { return !multiple && hayUno.load(); }
};

// Todo lo de un cuadro. Se comparte (shared_ptr) entre los hilos: si uno
// lee el codigo buscado, ml_leer devuelve enseguida y los hilos que siguen
// trabajando terminan solos sobre su propia copia, sin hacer esperar a nadie.
struct Trabajo {
  Reloj::time_point inicio = Reloj::now();
  int ancho = 0, alto = 0, fila = 0;
  std::vector<uint8_t> copia; // pixeles propios (los de Dart se reusan en el proximo cuadro)
  const uint8_t* px = nullptr;
  prep::Estadistica est{};
  Lector lector;
  bool conTope = false;
  int presupuesto_us = 0;

  // Zona de trabajo: buscando UN codigo, la central (75%: lo que se ve en
  // la ventanita); en conteo multiple, todo el cuadro. La ajustada (60%) es
  // para los pasos caros: cuesta menos y el umbral por linea mezcla menos
  // fondo con las barras.
  int zw = 0, zh = 0, zx = 0, zy = 0, rw = 0, rh = 0, rx = 0, ry = 0;

  std::atomic<int> tiempos[ML_PASOS] = {};
  std::atomic<int> pasosHechos{0};
  std::mutex espera;
  std::condition_variable aviso;
  int trabajando = 0;

  int usado() const {
    return (int)std::chrono::duration_cast<std::chrono::microseconds>(Reloj::now() - inicio).count();
  }
  ImageView entrada() const { return ImageView(px, ancho, alto, ImageFormat::Lum, fila); }
  const uint8_t* zona() const { return px + (size_t)zy * fila + zx; }
  const uint8_t* ajustada() const { return px + (size_t)ry * fila + rx; }
  Afin enZona() const { return Afin::desplazar((float)zx, (float)zy); }
  Afin enAjustada() const { return Afin::desplazar((float)rx, (float)ry); }

  bool conDetector = false;
  // Cuadro liviano del intercalado: sin el lector en tonos de gris (en el
  // telefono le sumaba 30-70 ms a cada cuadro con un codigo que no se lee).
  bool liviano = false;

  void rapido() {
    // Sobre la imagen original y con mas lineas de barrido (tryHarder): lo
    // normal se lee aca, sin preparar nada. Sin invertido (tiene su paso).
    // Buscando todos con el detector, los 1D los ubica OpenCV: aca basta un
    // barrido liviano (sobre todo para los 2D).
    auto o = lector.opciones(!(lector.multiple && conDetector));
    o.setTryInvert(false);
    lector.leer(entrada().cropped(zx, zy, zw, zh), o, ML_PASO_RAPIDO, enZona(), false, true);
  }
  void invertido() {
    auto img = prep::invertir(zona(), zw, zh, fila);
    lector.leer(img.vista(), lector.opciones(false), ML_PASO_INVERTIDO, enZona(), true);
  }
  void reflejos() {
    // 1D: promedio a lo largo de las barras + normalizacion local (bolsas
    // arrugadas, sombras, reflejos parciales). Dos tamanos de vecindario:
    // el grande para manchas amplias, el chico para sombras cortadas.
    auto o = lector.opciones(true, true);
    for (const int radio : {std::max(15, ancho / 33), std::max(10, ancho / 63)}) {
      auto img = prep::afinar1D(ajustada(), rw, rh, fila, 8, radio);
      lector.leer(img.vista(), o, ML_PASO_REFLEJOS, enAjustada());
      if (lector.listo() || (conTope && usado() >= presupuesto_us)) return;
    }
    // 2D (no tiene "a lo largo"): normalizacion local + enfoque.
    auto img = prep::enfocar(prep::normalizarLocal(zona(), zw, zh, fila, std::max(15, ancho / 33)), 1.0f);
    lector.leer(img.vista(), o, ML_PASO_REFLEJOS, enZona());
  }
  void rotado() {
    // Girado 45: con las rotaciones de 90 de zxing cubre cualquier angulo.
    auto img = prep::rotar45(ajustada(), rw, rh, fila);
    const float r = 0.70710678f, c = img.ancho / 2.0f;
    // Inversa de prep::rotar45 (ver preparar.cpp), mas el desplazamiento de la zona.
    const Afin t{r, r, -r, r, rw / 2.0f - 2 * r * c + rx, rh / 2.0f + ry};
    lector.leer(img.vista(), lector.opciones(false), ML_PASO_ROTADO, t);
    if (!lector.listo()) {
      auto fino = prep::afinar1D(img.px.data(), img.ancho, img.alto, img.ancho, 6, std::max(15, img.ancho / 20));
      lector.leer(fino.vista(), lector.opciones(true, true), ML_PASO_ROTADO, t);
    }
  }
  void pocaLuz() {
    auto img = prep::clahe(zona(), zw, zh, fila, 8, 8, 3.0f);
    lector.leer(img.vista(), lector.opciones(true, true), ML_PASO_POCA_LUZ, enZona());
  }
  void completo() {
    // Con esfuerzo: mas lineas, rotaciones de 90 y 2D invertido.
    lector.leer(entrada().cropped(zx, zy, zw, zh), lector.opciones(true), ML_PASO_COMPLETO, enZona(), false, true);
  }
  void ampliado() {
    // Chico, lejos o borroso: centro ampliado 2x y enfocado.
    const int aw = rw * 2 / 3, ah = rh * 2 / 3, ax = (rw - aw) / 2, ay = (rh - ah) / 2;
    const Afin t = Afin::desplazar((float)(rx + ax), (float)(ry + ay), 0.5f);
    auto img = prep::ampliar2x(ajustada() + (size_t)ay * fila + ax, aw, ah, fila);
    lector.leer(prep::enfocar(img, 1.5f).vista(), lector.opciones(true, true), ML_PASO_AMPLIADO, t);
    if (!lector.listo()) {
      auto fino = prep::afinar1D(img.px.data(), img.ancho, img.alto, img.ancho, 6, std::max(15, img.ancho / 20));
      lector.leer(fino.vista(), lector.opciones(true, true), ML_PASO_AMPLIADO, t);
    }
  }

  std::atomic<int> regiones{-1};
  // Zonas donde OpenCV ve un codigo que no se pudo leer (para la marca ⚠️).
  std::vector<std::array<float, 8>> sinLeer;

  // OpenCV ubica cada codigo 1D; cada uno se recorta, se endereza y se
  // decodifica por separado, en paralelo. Lee cualquier angulo y el costo
  // crece por codigo, no por tamano del cuadro. Solo se decodifica donde
  // hay un codigo (menos lecturas falsas sobre texto o rayas).
  void detector() {
#ifdef ML_CON_OPENCV
    const auto qs = det::detectar(zona(), zw, zh, fila);
    regiones = (int)qs.size();
    if (qs.empty()) return;
    std::atomic<int> siguiente{0};
    std::vector<char> leidoK(qs.size(), 0);
    auto trabajar = [&] {
      for (int k; (k = siguiente++) < (int)qs.size();) {
        if (lector.listo()) return;
        leidoK[k] = 1; // se corrige abajo si ningun intento lee
        auto rec = det::enderezar(zona(), zw, zh, fila, qs[k]);
        const Afin a{rec.a, rec.b, rec.c, rec.d, rec.tx + zx, rec.ty + zy};
        // El recorte esta enderezado (y ampliado si es chico): tambien
        // es imagen preparada, se piden 3 lineas iguales.
        auto o = lector.opciones(false, true);
        o.setMaxNumberOfSymbols(1);
        if (lector.leer(rec.img.vista(), o, ML_PASO_DETECTOR, a) > 0) continue;
        auto eq = det::clahe(rec.img);
        auto o2 = lector.opciones(true, true);
        o2.setMaxNumberOfSymbols(1);
        // Con contraste ecualizado zxing a veces "lee" un EAN que no es
        // (banco: 0733900815114 de 7753608815714 movido): se descarta si sus
        // digitos no calzan con los tonos de gris del recorte.
        auto validar = [&](const Barcode& b) {
          const auto f = b.format(); // (Symbology() junta EAN y UPC en una familia)
          if (f != BarcodeFormat::EAN13 && f != BarcodeFormat::UPCA && f != BarcodeFormat::EAN8) return true;
          return gris::verificarEan(rec.img, f == BarcodeFormat::UPCA ? "0" + b.text() : b.text()) >= 0;
        };
        if (lector.leer(eq.vista(), o2, ML_PASO_DETECTOR_PREP, a, false, false, validar) > 0) continue;
        if (lector.leer(prep::invertir(eq.px.data(), eq.ancho, eq.alto, eq.ancho).vista(), o2, ML_PASO_DETECTOR_PREP, a,
                        true, false, validar) > 0)
          continue;
        if (leerGris(rec, a)) continue;
        if (leerRed(rec, a)) continue;
        if (leerRestaurado(rec, a)) continue;
        leidoK[k] = 0;
      }
    };
    const int n = std::min((int)qs.size(), std::max(1, hilosEnUso()));
    std::vector<std::thread> grupo;
    for (int h = 1; h < n; h++) grupo.emplace_back(trabajar);
    trabajar();
    for (auto& g : grupo) g.join();

    // Sin leer: ni sus intentos ni otro paso leyeron un codigo con centro en la zona.
    std::lock_guard<std::mutex> l(lector.cerrojo);
    for (size_t k = 0; k < qs.size(); k++) {
      if (leidoK[k] || lector.listo()) continue;
      std::array<float, 8> q;
      for (int i = 0; i < 4; i++) {
        q[i * 2] = qs[k][i * 2] + zx;
        q[i * 2 + 1] = qs[k][i * 2 + 1] + zy;
      }
      const bool cubierto = std::any_of(lector.leidos.begin(), lector.leidos.end(), [&](const Lectura& r) {
        return dentro(q, r.cx, r.cy);
      });
      if (!cubierto) sinLeer.push_back(q);
    }
#endif
  }

#ifdef ML_CON_OPENCV
  // EAN/UPC borroso o movido: el recorte se lee en tonos de gris.
  bool leerGris(const det::Recorte& rec, const Afin& a) {
    const int32_t m = lector.mascara;
    const bool ean13 = m == 0 || (m & (ML_EAN13 | ML_UPCA)), ean8 = m == 0 || (m & ML_EAN8);
    if (liviano || (!ean13 && !ean8)) return false;
    const auto t0 = Reloj::now();
    gris::Resultado g;
    const bool ok = gris::leerEan(rec.img, ean13, ean8, g);
    tiempos[ML_PASO_GRIS] += (int)std::chrono::duration_cast<std::chrono::microseconds>(Reloj::now() - t0).count();
    if (!ok) return false;
    Lectura l;
    l.texto = g.texto;
    l.formato = g.ean8 ? BarcodeFormat::EAN8 : BarcodeFormat::EAN13;
    // Solo UPC-A pedido: un EAN-13 que empieza con 0 es un UPC-A.
    if (!g.ean8 && m != 0 && !(m & ML_EAN13)) {
      if (g.texto[0] != '0') return false;
      l.texto = g.texto.substr(1);
      l.formato = BarcodeFormat::UPCA;
    }
    l.pos = {PointF(g.x0, g.y0), PointF(g.x1, g.y0), PointF(g.x1, g.y1), PointF(g.x0, g.y1)};
    l.paso = ML_PASO_GRIS;
    l.aEntrada = a;
    return lector.agregar(std::move(l)) > 0;
  }
#endif

#ifdef ML_CON_OPENCV
  // Ultimo intento con un EAN-13/UPC-A: la red neuronal propia. Solo en los
  // cuadros de pasos dificiles (como el lector en tonos de gris).
  bool leerRed(const det::Recorte& rec, const Afin& a) {
    const int32_t m = lector.mascara;
    if (liviano || !(m == 0 || (m & (ML_EAN13 | ML_UPCA)))) return false;
    const auto t0 = Reloj::now();
    red::Resultado r;
    const bool ok = red::leerEan(rec.img, r);
    tiempos[ML_PASO_RED] += (int)std::chrono::duration_cast<std::chrono::microseconds>(Reloj::now() - t0).count();
    if (!ok) return false;
    // Los digitos tienen que calzar con los tonos de gris (o no poder saberse).
    if (gris::verificarEan(rec.img, r.texto) < 0) return false;
    Lectura l;
    l.texto = r.texto;
    l.formato = BarcodeFormat::EAN13;
    if (m != 0 && !(m & ML_EAN13)) {
      if (r.texto[0] != '0') return false;
      l.texto = r.texto.substr(1);
      l.formato = BarcodeFormat::UPCA;
    }
    const float w = (float)rec.img.ancho, h = (float)rec.img.alto;
    l.pos = {PointF(0, h * 0.35f), PointF(w, h * 0.35f), PointF(w, h * 0.65f), PointF(0, h * 0.65f)};
    l.paso = ML_PASO_RED;
    l.aEntrada = a;
    return lector.agregar(std::move(l)) > 0;
  }
#endif

#ifdef ML_CON_OPENCV
  // Cualquier 1D borroso o movido: la red de restauracion saca las barras
  // nitidas y zxing las lee (con sus controles). Solo en los cuadros de pasos
  // dificiles.
  bool leerRestaurado(const det::Recorte& rec, const Afin& a) {
    if (liviano) return false;
    const auto t0 = Reloj::now();
    std::vector<uint8_t> barras;
    const bool ok = red::restaurar(rec.img, barras);
    auto medir = [&] {
      tiempos[ML_PASO_RESTAURADO] +=
          (int)std::chrono::duration_cast<std::chrono::microseconds>(Reloj::now() - t0).count();
    };
    if (!ok || std::count(barras.begin(), barras.end(), 1) < 10) {
      medir();
      return false;
    }
    // Imagen nitida: 2 pixeles por muestra, 8 filas iguales.
    constexpr int kEsc = 2, kFilas = 8;
    const int w = (int)barras.size() * kEsc;
    std::vector<uint8_t> px((size_t)w * kFilas);
    for (int x = 0; x < w; x++) {
      const uint8_t v = barras[x / kEsc] ? 0 : 255;
      for (int y = 0; y < kFilas; y++) px[(size_t)y * w + x] = v;
    }
    auto o = lector.opciones(false);
    o.setMaxNumberOfSymbols(1);
    o.setTryRotate(false);
    o.setTryDownscale(false);
    auto encontrados = ReadBarcodes(ImageView(px.data(), w, kFilas, ImageFormat::Lum), o);
    medir();
    for (auto& b : encontrados) {
      if (!b.isValid() || !confiable(b)) continue;
      const auto f = b.format();
      if ((f == BarcodeFormat::EAN13 || f == BarcodeFormat::UPCA || f == BarcodeFormat::EAN8) &&
          gris::verificarEan(rec.img, f == BarcodeFormat::UPCA ? "0" + b.text() : b.text()) < 0)
        continue;
      Lectura l(b, ML_PASO_RESTAURADO, a, false);
      // Posicion: de la imagen restaurada al recorte (banda central).
      const float escala = (float)(rec.img.ancho - 1) / ((float)barras.size() - 1) / kEsc;
      float x0 = 1e9f, x1 = -1e9f;
      for (const auto& p : b.position()) {
        x0 = std::min(x0, (float)p.x);
        x1 = std::max(x1, (float)p.x);
      }
      const float h = (float)rec.img.alto;
      l.pos = {PointF(x0 * escala, h * 0.35f), PointF(x1 * escala, h * 0.35f), PointF(x1 * escala, h * 0.65f),
               PointF(x0 * escala, h * 0.65f)};
      if (lector.agregar(std::move(l)) > 0) return true;
    }
    return false;
  }
#endif

  // Punto dentro de un cuadrilatero convexo (mismo lado de los 4 bordes).
  static bool dentro(const std::array<float, 8>& q, float x, float y) {
    int signo = 0;
    for (int i = 0; i < 4; i++) {
      const float ax = q[i * 2], ay = q[i * 2 + 1], bx = q[(i + 1) % 4 * 2], by = q[(i + 1) % 4 * 2 + 1];
      const float c = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
      const int s = c > 0 ? 1 : (c < 0 ? -1 : 0);
      if (s == 0) continue;
      if (signo == 0) signo = s;
      else if (s != signo) return false;
    }
    return true;
  }

  void hacer(int paso) {
    if (lector.listo()) return;
    const int antes = usado();
    switch (paso) {
    case ML_PASO_RAPIDO: rapido(); break;
    case ML_PASO_INVERTIDO: invertido(); break;
    case ML_PASO_REFLEJOS: reflejos(); break;
    case ML_PASO_ROTADO: rotado(); break;
    case ML_PASO_POCA_LUZ: pocaLuz(); break;
    case ML_PASO_COMPLETO: completo(); break;
    case ML_PASO_AMPLIADO: ampliado(); break;
    case ML_PASO_DETECTOR: detector(); break;
    }
    tiempos[paso] = std::max(1, usado() - antes);
    pasosHechos++;
    if (lector.cuantos.load() > 0) {
      // Despierta a ml_leer, que espera el primer codigo nuevo (no a todos los hilos).
      std::lock_guard<std::mutex> l(espera);
      aviso.notify_all();
    }
  }
};

#ifdef ML_CON_OPENCV
// Verificacion de EAN/UPC contra los tonos de gris, con memoria por valor (el
// mismo codigo se lee en muchos cuadros seguidos y verificar cuesta).
// En el telefono zxing leyo 4750412416093 de la caja 7750082416093 sobre la
// imagen original (v0.13): pasaba el digito verificador.
std::mutex gCerrojoVerificados;
std::unordered_map<std::string, std::pair<int, Reloj::time_point>> gVerificados;

bool esEan(BarcodeFormat f) {
  return f == BarcodeFormat::EAN13 || f == BarcodeFormat::UPCA || f == BarcodeFormat::EAN8;
}

int verificarLectura(const Lectura& l, const uint8_t* px, int ancho, int alto, int fila) {
  const std::string texto = l.formato == BarcodeFormat::UPCA ? "0" + l.texto : l.texto;
  const auto ahora = Reloj::now();
  {
    std::lock_guard<std::mutex> c(gCerrojoVerificados);
    const auto it = gVerificados.find(texto);
    // Lo confirmado vale 10 s; lo rechazado o dudoso, medio segundo.
    if (it != gVerificados.end() &&
        ahora - it->second.second < std::chrono::milliseconds(it->second.first == 1 ? 10000 : 500))
      return it->second.first;
  }
  // Recorte enderezado alrededor del codigo (zxing da una linea o un cuadrilatero).
  det::Cuadrilatero q;
  for (int i = 0; i < 4; i++) {
    q[i * 2] = l.aEntrada.a * l.pos[i].x + l.aEntrada.b * l.pos[i].y + l.aEntrada.tx;
    q[i * 2 + 1] = l.aEntrada.c * l.pos[i].x + l.aEntrada.d * l.pos[i].y + l.aEntrada.ty;
  }
  int r = 0;
  try {
    const auto rec = det::enderezar(px, ancho, alto, fila, q);
    r = gris::verificarEan(rec.img, texto);
  } catch (...) {
    r = 0;
  }
  std::lock_guard<std::mutex> c(gCerrojoVerificados);
  if (gVerificados.size() > 200) gVerificados.clear();
  gVerificados[texto] = {r, ahora};
  return r;
}
#endif

void copiarTexto(char* destino, size_t capacidad, const std::string& texto) {
  const size_t n = std::min(texto.size(), capacidad - 1);
  std::memcpy(destino, texto.data(), n);
  destino[n] = 0;
}

} // namespace

extern "C" void ml_configurar(int32_t hilos) { gHilos = std::max(0, (int)hilos); }

extern "C" void ml_configurar_detector(int32_t activo) { gDetector = activo != 0; }

extern "C" int32_t ml_con_opencv(void) {
#ifdef ML_CON_OPENCV
  return 1;
#else
  return 0;
#endif
}

extern "C" int32_t ml_leer(const uint8_t* datos, int32_t ancho, int32_t alto, int32_t bytes_por_fila,
                           int32_t formato_pixel, int32_t formatos, int32_t modo, int32_t presupuesto_us,
                           int32_t ronda, ml_codigo* salida, int32_t max_salida, ml_info* info) {
  const auto inicio = Reloj::now();
  auto usado = [&] {
    return (int32_t)std::chrono::duration_cast<std::chrono::microseconds>(Reloj::now() - inicio).count();
  };
  ml_info nada;
  if (!info) info = &nada;
  std::memset(info, 0, sizeof(ml_info));
  if (!datos || ancho <= 0 || alto <= 0 || !salida || max_salida <= 0) return 0;

  try {
    auto t = std::make_shared<Trabajo>();
    t->inicio = inicio;
    t->ancho = ancho;
    t->alto = alto;
    const int hilos = hilosEnUso();
    const int fila = bytes_por_fila > 0 ? bytes_por_fila : ancho;
    if (formato_pixel == ML_PIXEL_BGRA) {
      // iOS: se convierte a luminancia (ya queda en memoria propia).
      t->copia = prep::deBgra(datos, ancho, alto, fila).px;
      t->fila = ancho;
    } else if (hilos > 1) {
      // En paralelo los hilos pueden seguir despues de devolver: copia propia.
      t->copia.resize((size_t)ancho * alto);
      for (int y = 0; y < alto; y++) std::memcpy(&t->copia[(size_t)y * ancho], datos + (size_t)y * fila, ancho);
      t->fila = ancho;
    } else {
      t->fila = fila; // uno tras otro: se lee directo, sin copiar
    }
    t->px = t->copia.empty() ? datos : t->copia.data();

    t->est = prep::medir(t->px, ancho, alto, t->fila);
    info->brillo = t->est.brillo;
    info->contraste = t->est.contraste;
    info->quemados = t->est.quemados;
    info->nitidez = t->est.nitidez;
    info->sugerir_linterna = t->est.brillo < 60 ? 1 : 0;
    info->hilos = hilos;
    info->regiones = -1;

    t->lector.formatos = aFormatosZx(formatos);
    t->lector.mascara = formatos;
    t->lector.multiple = (modo & ML_MODO_TODOS) != 0;
    const bool completo = (modo & ML_MODO_CUADRO_COMPLETO) != 0;
    t->conTope = hilos <= 1 && presupuesto_us > 0;
    t->presupuesto_us = presupuesto_us;
    // Buscando uno: lo que se ve en la ventanita de la camara (cuadrada, al
    // centro de la imagen vertical). El sensor esta girado 90 grados: el ancho
    // del cuadro es el alto de la pantalla, asi que se toma el centro del
    // ancho (56%) y todo el alto.
    const bool horizontal = ancho >= alto;
    t->zw = completo ? ancho : (horizontal ? ancho * 6 / 10 : ancho);
    t->zh = completo ? alto : (horizontal ? alto : alto * 6 / 10);
    t->zx = (ancho - t->zw) / 2;
    t->zy = (alto - t->zh) / 2;
    t->rw = completo ? t->zw : t->zw * 8 / 10;
    t->rh = completo ? t->zh : t->zh * 8 / 10;
    t->rx = (ancho - t->rw) / 2;
    t->ry = (alto - t->rh) / 2;

    // Pasos dificiles, de barato a caro. Segun la luz medida, primero el que
    // mas probablemente resuelva.
    std::vector<int> dificiles = {ML_PASO_INVERTIDO, ML_PASO_REFLEJOS, ML_PASO_ROTADO,
                                  ML_PASO_POCA_LUZ,  ML_PASO_COMPLETO, ML_PASO_AMPLIADO};
    auto adelantar = [&](int paso) {
      auto it = std::find(dificiles.begin(), dificiles.end(), paso);
      if (it != dificiles.end()) std::rotate(dificiles.begin(), it, it + 1);
    };
    if (t->est.brillo < 70) adelantar(ML_PASO_POCA_LUZ);
    if (t->est.quemados >= 3 || t->est.contraste < 30 || t->est.brillo < 70) adelantar(ML_PASO_REFLEJOS);

#ifdef ML_CON_OPENCV
    const bool conDetector = gDetector.load();
#else
    const bool conDetector = false;
#endif
    t->conDetector = conDetector;
    // Cuadro de pasos dificiles que viene mas borroso que el promedio, o con
    // el telefono moviendose rapido (giroscopio): se aplaza al siguiente
    // (hasta 3 veces seguidas).
    bool aplazar = false;
    {
      const int n16 = t->est.nitidez * 16;
      int prom = gNitidezProm.load();
      prom = prom == 0 ? n16 : prom + (n16 - prom) / 8;
      gNitidezProm = prom;
      const bool pesado = (modo & ML_MODO_INTERCALAR) && ronda % 4 == 0;
      const bool moviendo = (modo & ML_MODO_MOVIENDO) != 0;
      if (pesado && (moviendo || n16 * 100 < prom * 85) && gAplazados.load() < 3) {
        aplazar = true;
        gAplazados++;
      } else if (pesado) {
        gAplazados = 0;
      }
    }
    t->liviano = ((modo & ML_MODO_INTERCALAR) && ronda % 4 != 0) || aplazar;
    t->hacer(ML_PASO_RAPIDO);
    // El detector va siempre despues del rapido (es barato: 26-64 ms en el
    // telefono, y junto con el rapido es lo que lee los codigos reales).
    if (conDetector && !t->lector.listo() && !(modo & ML_MODO_SOLO_RAPIDO)) t->hacer(ML_PASO_DETECTOR);
    const int delRapido = t->lector.cuantos.load();

    const int n = (int)dificiles.size();
    // Buscando todos: si el rapido ya leyo, el cuadro vuelve enseguida; los
    // pasos dificiles corren 1 de cada 3 cuadros igual, por si al lado de los
    // faciles hay uno dificil. (En el telefono, esperar a todos los pasos con
    // el codigo ya leido dejaba cuadros de 350-650 ms.)
    // Con el detector: si leyo todo lo que ubico, no hace falta mas.
    const bool detectorCompleto = conDetector && t->regiones.load() > 0 && delRapido >= t->regiones.load();
    const bool rapidoAlcanza = t->lector.multiple && delRapido > 0 && (ronda % 3 != 0 || detectorCompleto);
    // Intercalado: un cuadro liviano (solo rapido, y el detector si se buscan
    // todos) y uno con los pasos dificiles. En el telefono los codigos reales
    // los leia sobre todo el rapido apenas la imagen salia nitida, y correr
    // los dificiles en cada cuadro bajaba la camara de 20 a 7 cuadros/s.
    // Los demas pasos dificiles casi nunca resolvieron con productos reales y
    // frenaban la camara a 4-5 cuadros/s: van 1 de cada 4 cuadros.
    const bool liviano = t->liviano;
    if (t->lector.listo() || rapidoAlcanza || liviano || (modo & ML_MODO_SOLO_RAPIDO)) {
      info->siguiente_ronda = ronda + 1;
    } else if (hilos > 1) {
      // En paralelo: todos los pasos dificiles a la vez, repartidos en los
      // nucleos; en cada cuadro se prueba todo. Buscando uno, se devuelve
      // apenas alguno lee (los demas terminan solos y se descartan); en
      // conteo multiple se espera a todos para juntar todo lo leido.
      auto cola = std::make_shared<std::atomic<int>>(0);
      const int grupo = std::min(hilos, n);
      t->trabajando = grupo;
      for (int h = 0; h < grupo; h++) {
        std::thread([t, cola, dificiles] {
          for (int k; (k = (*cola)++) < (int)dificiles.size();) t->hacer(dificiles[k]);
          std::lock_guard<std::mutex> l(t->espera);
          t->trabajando--;
          t->aviso.notify_all();
        }).detach();
      }
      std::unique_lock<std::mutex> l(t->espera);
      // Vuelve apenas algun paso lee algo nuevo; los demas terminan solos y se
      // descartan (el proximo cuadro vuelve a probar todo).
      auto hayNuevo = [&] { return t->trabajando == 0 || t->lector.cuantos.load() > delRapido; };
      if (t->lector.multiple && delRapido > 0) {
        // Buscando todos y con algo ya leido: se espera poco a los dificiles
        // (lo que lean despues se descarta; el proximo cuadro vuelve a probar).
        t->aviso.wait_for(l, std::chrono::milliseconds(120), hayNuevo);
      } else if (modo & ML_MODO_INTERCALAR) {
        // Con la camara en vivo: tope de 200 ms para no trabar la camara.
        t->aviso.wait_for(l, std::chrono::milliseconds(200), hayNuevo);
      } else {
        t->aviso.wait(l, hayNuevo);
      }
      info->siguiente_ronda = ronda + 1;
    } else {
      // Uno tras otro, con tope de tiempo; el siguiente cuadro sigue donde quedo.
      const int desde = ((ronda % n) + n) % n;
      int hechos = 0;
      while (hechos < n && !t->lector.listo()) {
        if (hechos > 0 && presupuesto_us > 0 && usado() >= presupuesto_us) break;
        t->hacer(dificiles[(desde + hechos) % n]);
        hechos++;
      }
      info->siguiente_ronda = ronda + std::max(hechos, 1);
    }
    // Aplazado: el proximo cuadro vuelve a ser el de pasos dificiles.
    if (aplazar) info->siguiente_ronda = ronda;
    for (int p = 0; p < ML_PASOS; p++) info->tiempo_paso_us[p] = t->tiempos[p].load();
    info->pasos = t->pasosHechos.load();
    info->ilegibles = t->lector.ilegibles.load();
    info->regiones = t->regiones.load();

    // Copia de lo leido bajo el cerrojo: puede haber hilos todavia agregando.
    std::vector<Lectura> leidos;
    std::vector<std::array<float, 8>> sinLeer;
    {
      std::lock_guard<std::mutex> l(t->lector.cerrojo);
      leidos = t->lector.leidos;
      sinLeer = t->sinLeer;
    }
    int32_t escritos = 0;
    for (const auto& lec : leidos) {
      if (escritos >= max_salida) break;
      // Lo leido en tonos de gris no se da por verificado: en el banco
      // sintetico se equivoco 1 vez cada ~6000 casos dificiles; la app lo
      // cuenta cuando se repite.
      int verificado = 0;
#ifdef ML_CON_OPENCV
      if (lec.paso != ML_PASO_GRIS && lec.paso != ML_PASO_RED && lec.paso != ML_PASO_RESTAURADO &&
          esEan(lec.formato)) {
        verificado = verificarLectura(lec, t->px, t->ancho, t->alto, t->fila);
        if (verificado < 0) {
          info->ilegibles++; // los digitos no calzan con la imagen: lectura falsa
          continue;
        }
      }
#endif
      ml_codigo& c = salida[escritos++];
      std::memset(&c, 0, sizeof(ml_codigo));
      c.verificado = verificado == 1 ? 1 : 0;
      c.formato = aBit(lec.formato);
      c.paso = lec.paso;
      c.invertido = lec.invertido ? 1 : 0;
      const auto& pos = lec.pos;
      const Afin& a = lec.aEntrada;
      for (int i = 0; i < 4; i++) {
        c.x[i] = (int32_t)(a.a * pos[i].x + a.b * pos[i].y + a.tx);
        c.y[i] = (int32_t)(a.c * pos[i].x + a.d * pos[i].y + a.ty);
      }
      copiarTexto(c.nombre_formato, sizeof(c.nombre_formato), ToString(lec.formato));
      copiarTexto(c.texto, sizeof(c.texto), lec.texto);
    }
    for (const auto& q : sinLeer) {
      if (escritos >= max_salida) break;
      ml_codigo& c = salida[escritos++];
      std::memset(&c, 0, sizeof(ml_codigo));
      c.sin_leer = 1;
      c.paso = ML_PASO_DETECTOR;
      for (int i = 0; i < 4; i++) {
        c.x[i] = (int32_t)q[i * 2];
        c.y[i] = (int32_t)q[i * 2 + 1];
      }
    }
    info->microsegundos = usado();
    return escritos;
  } catch (...) {
    // Nunca dejar escapar una excepcion por FFI: se pierde el cuadro y listo.
    info->microsegundos = usado();
    return 0;
  }
}
