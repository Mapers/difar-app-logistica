#include "motor_lector.h"
#include "preparar.h"

#include "ReadBarcode.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

using namespace ZXing;

namespace {

using Reloj = std::chrono::steady_clock;

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
  bool multiple;
  std::vector<Lectura> leidos;

  ReaderOptions opciones(bool esfuerzo) const {
    ReaderOptions o;
    o.setFormats(formatos);
    o.setTextMode(TextMode::Plain);
    o.setTryRotate(true);
    o.setTryDownscale(true);
    o.setTryHarder(esfuerzo);
    o.setTryInvert(esfuerzo); // solo afecta a 2D; el 1D invertido tiene su propio paso
    o.setMaxNumberOfSymbols(multiple ? 255 : 1);
    return o;
  }

  void leer(const ImageView& img, const ReaderOptions& o, int paso, Afin t = {}, bool invertido = false) {
    for (auto& b : ReadBarcodes(img, o)) {
      if (!b.isValid() || !confiable(b)) continue;
      const bool repetido = std::any_of(leidos.begin(), leidos.end(), [&](const Lectura& l) {
        return l.codigo.text() == b.text() && Symbology(l.codigo.format()) == Symbology(b.format());
      });
      if (!repetido) leidos.push_back({std::move(b), paso, t, invertido});
    }
  }

  bool listo() const { return !multiple && !leidos.empty(); }
};

void copiarTexto(char* destino, size_t capacidad, const std::string& texto) {
  const size_t n = std::min(texto.size(), capacidad - 1);
  std::memcpy(destino, texto.data(), n);
  destino[n] = 0;
}

} // namespace

extern "C" int32_t ml_leer(const uint8_t* datos, int32_t ancho, int32_t alto, int32_t bytes_por_fila,
                           int32_t formato_pixel, int32_t formatos, int32_t multiple, int32_t presupuesto_us,
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
    // Luminancia: en Android el plano Y ya lo es (sin copiar); en iOS se convierte.
    prep::Gris bgra;
    const uint8_t* px = datos;
    int fila = bytes_por_fila > 0 ? bytes_por_fila : ancho;
    if (formato_pixel == ML_PIXEL_BGRA) {
      bgra = prep::deBgra(datos, ancho, alto, fila);
      px = bgra.px.data();
      fila = ancho;
    }
    const ImageView entrada(px, ancho, alto, ImageFormat::Lum, fila);

    const auto est = prep::medir(px, ancho, alto, fila);
    info->brillo = est.brillo;
    info->contraste = est.contraste;
    info->quemados = est.quemados;
    info->nitidez = est.nitidez;
    info->sugerir_linterna = est.brillo < 60 ? 1 : 0;

    Lector lector{aFormatosZx(formatos), multiple != 0, {}};

    // Zona de trabajo: buscando UN codigo, la zona central (lo que se ve en
    // la ventanita); en conteo multiple, todo el cuadro.
    const int zw = multiple ? ancho : ancho * 3 / 4, zh = multiple ? alto : alto * 3 / 4;
    const int zx = (ancho - zw) / 2, zy = (alto - zh) / 2;
    const uint8_t* zona = px + (size_t)zy * fila + zx;
    const ImageView vistaZona = entrada.cropped(zx, zy, zw, zh);
    const Afin enZona = Afin::desplazar((float)zx, (float)zy);
    // Zona ajustada (60% buscando uno) para los pasos caros: cuesta menos y el
    // umbral por linea mezcla menos fondo con las barras.
    const int rw = multiple ? zw : ancho * 6 / 10, rh = multiple ? zh : alto * 6 / 10;
    const int rx = (ancho - rw) / 2, ry = (alto - rh) / 2;
    const uint8_t* ajustada = px + (size_t)ry * fila + rx;
    const Afin enAjustada = Afin::desplazar((float)rx, (float)ry);

    using Paso = std::function<void()>;
    auto poca_luz = [&] {
      auto img = prep::clahe(zona, zw, zh, fila, 8, 8, 3.0f);
      lector.leer(img.vista(), lector.opciones(true), ML_PASO_POCA_LUZ, enZona);
    };
    auto reflejos = [&] {
      // 1D: promedio a lo largo de las barras + normalizacion local (bolsas
      // arrugadas, sombras, reflejos parciales). Dos tamanos de vecindario:
      // el grande para manchas amplias, el chico para sombras cortadas.
      auto o = lector.opciones(true);
      for (const int radio : {std::max(15, ancho / 33), std::max(10, ancho / 63)}) {
        auto img = prep::afinar1D(ajustada, rw, rh, fila, 8, radio);
        lector.leer(img.vista(), o, ML_PASO_REFLEJOS, enAjustada);
        if (lector.listo() || (presupuesto_us > 0 && usado() >= presupuesto_us)) return;
      }
      // 2D (no tiene "a lo largo"): normalizacion local + enfoque.
      auto img = prep::enfocar(prep::normalizarLocal(zona, zw, zh, fila, std::max(15, ancho / 33)), 1.0f);
      lector.leer(img.vista(), o, ML_PASO_REFLEJOS, enZona);
    };

    auto rapido = [&] { lector.leer(vistaZona, lector.opciones(false), ML_PASO_RAPIDO, enZona); };
    auto invertido = [&] {
      auto img = prep::invertir(zona, zw, zh, fila);
      lector.leer(img.vista(), lector.opciones(false), ML_PASO_INVERTIDO, enZona, true);
    };
    auto rotado = [&] {
      // Girado 45: con las rotaciones de 90 de zxing cubre cualquier angulo.
      auto img = prep::rotar45(ajustada, rw, rh, fila);
      const float r = 0.70710678f, c = img.ancho / 2.0f;
      // Inversa de prep::rotar45 (ver preparar.cpp), mas el desplazamiento de la zona.
      const Afin t{r, r, -r, r, rw / 2.0f - 2 * r * c + rx, rh / 2.0f + ry};
      lector.leer(img.vista(), lector.opciones(false), ML_PASO_ROTADO, t);
      if (!lector.listo()) {
        auto fino = prep::afinar1D(img.px.data(), img.ancho, img.alto, img.ancho, 6, std::max(15, img.ancho / 20));
        lector.leer(fino.vista(), lector.opciones(true), ML_PASO_ROTADO, t);
      }
    };
    auto completo = [&] {
      // Con esfuerzo: mas lineas, rotaciones de 90 y 2D invertido. Buscando
      // UN codigo basta la zona central (el apuntado esta ahi y cuesta un
      // tercio); en conteo multiple, todo el cuadro.
      lector.leer(vistaZona, lector.opciones(true), ML_PASO_COMPLETO, enZona);
    };
    auto ampliado = [&] {
      // Chico, lejos o borroso: centro ampliado 2x y enfocado.
      const int aw = rw * 2 / 3, ah = rh * 2 / 3, ax = (rw - aw) / 2, ay = (rh - ah) / 2;
      const Afin t = Afin::desplazar((float)(rx + ax), (float)(ry + ay), 0.5f);
      auto img = prep::ampliar2x(ajustada + (size_t)ay * fila + ax, aw, ah, fila);
      lector.leer(prep::enfocar(img, 1.5f).vista(), lector.opciones(true), ML_PASO_AMPLIADO, t);
      if (!lector.listo()) {
        auto fino = prep::afinar1D(img.px.data(), img.ancho, img.alto, img.ancho, 6, std::max(15, img.ancho / 20));
        lector.leer(fino.vista(), lector.opciones(true), ML_PASO_AMPLIADO, t);
      }
    };

    // Pasos dificiles, de barato a caro. Segun la luz medida, primero el que
    // mas probablemente resuelva.
    std::vector<std::pair<int, Paso>> dificiles = {
        {ML_PASO_INVERTIDO, invertido}, {ML_PASO_REFLEJOS, reflejos}, {ML_PASO_ROTADO, rotado},
        {ML_PASO_POCA_LUZ, poca_luz},   {ML_PASO_COMPLETO, completo}, {ML_PASO_AMPLIADO, ampliado},
    };
    auto adelantar = [&](int paso) {
      auto it = std::find_if(dificiles.begin(), dificiles.end(), [&](auto& p) { return p.first == paso; });
      if (it != dificiles.end()) std::rotate(dificiles.begin(), it, it + 1);
    };
    if (est.brillo < 70) adelantar(ML_PASO_POCA_LUZ);
    if (est.quemados >= 3 || est.contraste < 30 || est.brillo < 70) adelantar(ML_PASO_REFLEJOS);

    auto medir = [&](int paso, const Paso& hacer) {
      const int antes = usado();
      hacer();
      info->tiempo_paso_us[paso] = std::max(1, usado() - antes);
      info->pasos++;
    };
    medir(ML_PASO_RAPIDO, rapido);

    const int n = (int)dificiles.size();
    const int desde = ((ronda % n) + n) % n;
    int hechos = 0;
    while (hechos < n && !lector.listo()) {
      if (hechos > 0 && presupuesto_us > 0 && usado() >= presupuesto_us) break;
      const auto& [paso, hacer] = dificiles[(desde + hechos) % n];
      medir(paso, hacer);
      hechos++;
    }
    info->siguiente_ronda = ronda + std::max(hechos, 1);

    int32_t escritos = 0;
    for (const auto& l : lector.leidos) {
      if (escritos >= max_salida) break;
      ml_codigo& c = salida[escritos++];
      std::memset(&c, 0, sizeof(ml_codigo));
      c.formato = aBit(l.codigo.format());
      c.paso = l.paso;
      c.invertido = (l.invertido || l.codigo.isInverted()) ? 1 : 0;
      const auto& pos = l.codigo.position();
      const Afin& t = l.aEntrada;
      for (int i = 0; i < 4; i++) {
        c.x[i] = (int32_t)(t.a * pos[i].x + t.b * pos[i].y + t.tx);
        c.y[i] = (int32_t)(t.c * pos[i].x + t.d * pos[i].y + t.ty);
      }
      copiarTexto(c.nombre_formato, sizeof(c.nombre_formato), ToString(l.codigo.format()));
      copiarTexto(c.texto, sizeof(c.texto), l.codigo.text());
    }
    info->microsegundos = usado();
    return escritos;
  } catch (...) {
    // Nunca dejar escapar una excepcion por FFI: se pierde el cuadro y listo.
    info->microsegundos = usado();
    return 0;
  }
}
