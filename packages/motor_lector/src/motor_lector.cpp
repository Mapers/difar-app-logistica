#include "motor_lector.h"
#include "preparar.h"

#include "ReadBarcode.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace ZXing;

namespace {

using Reloj = std::chrono::steady_clock;

// Hilos para los pasos dificiles (ml_configurar). <= 1: uno tras otro,
// repartidos entre cuadros con [ronda].
std::atomic<int> gHilos{0}; // 0 = segun los nucleos del telefono

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
  Barcode codigo;
  int paso;
  Afin aEntrada;
  bool invertido;
};

struct Lector {
  BarcodeFormats formatos;
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
  void leer(const ImageView& img, ReaderOptions o, int paso, Afin t = {}, bool invertido = false,
            bool errores = false) {
    if (listo()) return;
    o.setReturnErrors(errores);
    auto encontrados = ReadBarcodes(img, o);
    std::lock_guard<std::mutex> l(cerrojo);
    for (auto& b : encontrados) {
      if (!b.isValid()) {
        if (b.error().type() == Error::Type::Checksum) ilegibles++;
        continue;
      }
      if (!confiable(b)) continue;
      const bool repetido = std::any_of(leidos.begin(), leidos.end(), [&](const Lectura& l) {
        return l.codigo.text() == b.text() && Symbology(l.codigo.format()) == Symbology(b.format());
      });
      if (!repetido) {
        leidos.push_back({std::move(b), paso, t, invertido});
        hayUno = true;
        cuantos++;
      }
    }
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

  void rapido() {
    // Sobre la imagen original y con mas lineas de barrido (tryHarder): lo
    // normal se lee aca, sin preparar nada. Sin invertido (tiene su paso).
    auto o = lector.opciones(true);
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

void copiarTexto(char* destino, size_t capacidad, const std::string& texto) {
  const size_t n = std::min(texto.size(), capacidad - 1);
  std::memcpy(destino, texto.data(), n);
  destino[n] = 0;
}

} // namespace

extern "C" void ml_configurar(int32_t hilos) { gHilos = std::max(0, (int)hilos); }

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

    t->lector.formatos = aFormatosZx(formatos);
    t->lector.multiple = (modo & ML_MODO_TODOS) != 0;
    const bool completo = (modo & ML_MODO_CUADRO_COMPLETO) != 0;
    t->conTope = hilos <= 1 && presupuesto_us > 0;
    t->presupuesto_us = presupuesto_us;
    t->zw = completo ? ancho : ancho * 3 / 4;
    t->zh = completo ? alto : alto * 3 / 4;
    t->zx = (ancho - t->zw) / 2;
    t->zy = (alto - t->zh) / 2;
    t->rw = completo ? t->zw : ancho * 6 / 10;
    t->rh = completo ? t->zh : alto * 6 / 10;
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

    t->hacer(ML_PASO_RAPIDO);
    const int delRapido = t->lector.cuantos.load();

    const int n = (int)dificiles.size();
    // Buscando todos: si el rapido ya leyo, el cuadro vuelve enseguida; los
    // pasos dificiles corren 1 de cada 3 cuadros igual, por si al lado de los
    // faciles hay uno dificil. (En el telefono, esperar a todos los pasos con
    // el codigo ya leido dejaba cuadros de 350-650 ms.)
    const bool rapidoAlcanza = t->lector.multiple && delRapido > 0 && ronda % 3 != 0;
    if (t->lector.listo() || rapidoAlcanza || (modo & ML_MODO_SOLO_RAPIDO)) {
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
      t->aviso.wait(l, [&] { return t->trabajando == 0 || t->lector.cuantos.load() > delRapido; });
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
    for (int p = 0; p < ML_PASOS; p++) info->tiempo_paso_us[p] = t->tiempos[p].load();
    info->pasos = t->pasosHechos.load();
    info->ilegibles = t->lector.ilegibles.load();

    // Copia de lo leido bajo el cerrojo: puede haber hilos todavia agregando.
    std::vector<Lectura> leidos;
    {
      std::lock_guard<std::mutex> l(t->lector.cerrojo);
      leidos = t->lector.leidos;
    }
    int32_t escritos = 0;
    for (const auto& lec : leidos) {
      if (escritos >= max_salida) break;
      ml_codigo& c = salida[escritos++];
      std::memset(&c, 0, sizeof(ml_codigo));
      c.formato = aBit(lec.codigo.format());
      c.paso = lec.paso;
      c.invertido = (lec.invertido || lec.codigo.isInverted()) ? 1 : 0;
      const auto& pos = lec.codigo.position();
      const Afin& a = lec.aEntrada;
      for (int i = 0; i < 4; i++) {
        c.x[i] = (int32_t)(a.a * pos[i].x + a.b * pos[i].y + a.tx);
        c.y[i] = (int32_t)(a.c * pos[i].x + a.d * pos[i].y + a.ty);
      }
      copiarTexto(c.nombre_formato, sizeof(c.nombre_formato), ToString(lec.codigo.format()));
      copiarTexto(c.texto, sizeof(c.texto), lec.codigo.text());
    }
    info->microsegundos = usado();
    return escritos;
  } catch (...) {
    // Nunca dejar escapar una excepcion por FFI: se pierde el cuadro y listo.
    info->microsegundos = usado();
    return 0;
  }
}
