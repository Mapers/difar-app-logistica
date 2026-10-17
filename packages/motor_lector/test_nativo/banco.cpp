// Banco de pruebas: genera cuadros de camara (1280x720, luminancia) con
// codigos en condiciones dificiles y compara zxing-cpp con sus opciones por
// defecto contra el motor de la app (ml_leer). Sale con 1 si el motor lee
// menos que zxing solo en alguna escena.
#include "motor_lector.h"

#include "BitMatrix.h"
#include "MultiFormatWriter.h"
#include "ReadBarcode.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <random>
#include <string>
#include <vector>

using namespace ZXing;

constexpr int W = 1280, H = 720;
using Img = std::vector<float>; // 0..255, W*H

struct Codigo {
  const char* nombre;
  BarcodeFormat formato;
  std::string texto;   // lo que se escribe
  std::string esperado; // lo que se debe leer
  int ancho, alto;     // tamano del simbolo en pixeles
};

// Dibuja el codigo en una etiqueta clara sobre un fondo de "carton" con ruido.
Img escena(const Codigo& c, float escala = 1, uint8_t tinta = 0, uint8_t papel = 255) {
  std::mt19937 rng(7);
  std::normal_distribution<float> ruido(0, 6);
  Img img(W * H);
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) img[y * W + x] = 120 + 25 * std::sin(x * 0.01f) * std::cos(y * 0.013f) + ruido(rng);

  const int cw = (int)(c.ancho * escala), ch = (int)(c.alto * escala);
  auto bits = MultiFormatWriter(c.formato).setMargin(0).encode(c.texto, cw, ch);
  const int bw = bits.width(), bh = bits.height();
  const int x0 = (W - bw) / 2, y0 = (H - bh) / 2, margen = std::max(16, bw / 5); // zona blanca: 1D pide ~10 modulos
  for (int y = y0 - margen; y < y0 + bh + margen; y++)
    for (int x = x0 - margen; x < x0 + bw + margen; x++)
      if (x >= 0 && y >= 0 && x < W && y < H) img[y * W + x] = papel;
  for (int y = 0; y < bh; y++)
    for (int x = 0; x < bw; x++)
      if (bits.get(x, y)) img[(y0 + y) * W + x0 + x] = tinta;
  return img;
}

void ruido(Img& img, float sigma, int semilla = 3) {
  std::mt19937 rng(semilla);
  std::normal_distribution<float> n(0, sigma);
  for (auto& v : img) v += n(rng);
}

void desenfocar(Img& img, int r) {
  Img t(img.size());
  for (int pasada = 0; pasada < 2; pasada++) { // horizontal y vertical
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        float s = 0;
        int n = 0;
        for (int d = -r; d <= r; d++) {
          const int xx = pasada == 0 ? x + d : x, yy = pasada == 0 ? y : y + d;
          if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
          s += img[yy * W + xx];
          n++;
        }
        t[y * W + x] = s / n;
      }
    img.swap(t);
  }
}

// Remapea con una funcion destino -> origen (vecino mas cercano).
void deformar(Img& img, const std::function<bool(float, float, float&, float&)>& origen) {
  Img t(img.size(), 128);
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) {
      float sx, sy;
      if (!origen(x, y, sx, sy)) continue;
      const int ix = (int)sx, iy = (int)sy;
      if (ix >= 0 && iy >= 0 && ix < W && iy < H) t[y * W + x] = img[iy * W + ix];
    }
  img.swap(t);
}

std::vector<uint8_t> aBytes(const Img& img) {
  std::vector<uint8_t> b(img.size());
  for (size_t i = 0; i < img.size(); i++) b[i] = (uint8_t)std::clamp(img[i], 0.0f, 255.0f);
  return b;
}

struct Escena {
  const char* nombre;
  std::function<Img(const Codigo&)> crear;
};

int main() {
  const std::vector<Codigo> codigos = {
      {"EAN-13", BarcodeFormat::EAN13, "775018200012", "7750182000123", 300, 140},
      {"Code128", BarcodeFormat::Code128, "LOTE-2026-A15", "LOTE-2026-A15", 380, 120},
      {"ITF-14", BarcodeFormat::ITF, "17750182000124", "17750182000124", 420, 120},
      {"QR", BarcodeFormat::QRCode, "DIFAR|PALLET|00042", "DIFAR|PALLET|00042", 200, 200},
      {"DataMatrix", BarcodeFormat::DataMatrix, "0107750182000124", "0107750182000124", 160, 160},
  };

  const std::vector<Escena> escenas = {
      {"normal", [](const Codigo& c) { return escena(c); }},
      {"sin luz", [](const Codigo& c) {
         auto i = escena(c);
         for (auto& v : i) v = v * 0.10f + 3;
         ruido(i, 3);
         return i;
       }},
      {"reflejo botella", [](const Codigo& c) {
         auto i = escena(c);
         // Brillo especular: velo que sube las barras y aplasta el contraste
         // en una franja (si satura del todo, no hay barras que leer: ahi la
         // app pide inclinar el telefono).
         for (int y = 0; y < H; y++)
           for (int x = 0; x < W; x++) {
             const float dx = (x - W * 0.47f) / 60.0f, dy = (y - H * 0.5f) / 260.0f;
             const float velo = std::exp(-(dx * dx + dy * dy));
             float& v = i[y * W + x];
             v = v * (1 - 0.75f * velo) + 250 * velo;
           }
         ruido(i, 4);
         return i;
       }},
      {"invertido", [](const Codigo& c) {
         auto i = escena(c, 1, 235, 30);
         ruido(i, 5);
         return i;
       }},
      {"bolsa sombra", [](const Codigo& c) {
         auto i = escena(c, 1, 95, 150);
         for (int y = 0; y < H; y++)
           for (int x = 0; x < W; x++) {
             // Sombra en diagonal + arrugas (bandas de luz) del plastico.
             const float sombra = 0.35f + 0.65f * std::clamp((x + y * 0.6f) / (W * 0.9f), 0.0f, 1.0f);
             const float arruga = 1 + 0.18f * std::sin(x * 0.045f + y * 0.02f);
             i[y * W + x] *= sombra * arruga;
           }
         ruido(i, 7);
         return i;
       }},
      {"chico y borroso", [](const Codigo& c) {
         // ~2 px por barra fina: el limite razonable (menos = acercarse o zoom).
         auto i = escena(c, 0.62f);
         desenfocar(i, 1);
         ruido(i, 4);
         return i;
       }},
      {"rotado 35", [](const Codigo& c) {
         auto i = escena(c);
         const float a = 35 * 3.14159f / 180, co = std::cos(a), si = std::sin(a);
         deformar(i, [&](float x, float y, float& sx, float& sy) {
           const float dx = x - W / 2.0f, dy = y - H / 2.0f;
           sx = co * dx + si * dy + W / 2.0f;
           sy = -si * dx + co * dy + H / 2.0f;
           return true;
         });
         ruido(i, 4);
         return i;
       }},
      {"botella curva", [](const Codigo& c) {
         auto i = escena(c);
         // Proyeccion de un cilindro: se comprime hacia los bordes y se oscurece.
         const float R = 300;
         deformar(i, [&](float x, float y, float& sx, float& sy) {
           const float u = (x - W / 2.0f) / R;
           if (std::abs(u) >= 1) return false;
           sx = W / 2.0f + R * std::asin(u);
           sy = y;
           return true;
         });
         for (int y = 0; y < H; y++)
           for (int x = 0; x < W; x++) {
             const float u = std::abs((x - W / 2.0f) / 300.0f);
             i[y * W + x] *= u < 1 ? std::sqrt(1 - u * u) * 0.8f + 0.2f : 0.2f;
           }
         ruido(i, 5);
         return i;
       }},
  };

  // Tope por cuadro en la PC; en un telefono medio el mismo trabajo tarda ~3x.
  const int presupuesto = std::getenv("BANCO_US") ? std::atoi(std::getenv("BANCO_US")) : 15000;
  int peores = 0, totalBase = 0, totalMotor = 0, peorCuadro = 0;
  double tiempoTotal = 0; // suma, en los leidos, del tiempo de todos los cuadros hasta leer
  const int hilos = std::getenv("BANCO_HILOS") ? std::atoi(std::getenv("BANCO_HILOS")) : 0;
  ml_configurar(hilos);
  std::printf("hilos: %s   tope por cuadro (solo uno tras otro): %.1f ms\n",
              hilos == 0 ? "segun nucleos (paralelo)" : std::to_string(hilos).c_str(), presupuesto / 1000.0);
  std::printf("%-17s %-11s %-6s %-6s %-5s %-7s %s\n", "escena", "codigo", "zxing", "motor", "paso", "cuadros",
              "ms peor cuadro  [ms por paso | por cuadro]");
  for (const auto& e : escenas) {
    for (const auto& c : codigos) {
      const auto bytes = aBytes(e.crear(c));
      if (std::getenv("BANCO_PGM")) { // guarda la escena para mirarla
        const std::string ruta = std::string(std::getenv("BANCO_PGM")) + "/" + e.nombre + "_" + c.nombre + ".pgm";
        if (FILE* f = std::fopen(ruta.c_str(), "wb")) {
          std::fprintf(f, "P5 %d %d 255\n", W, H);
          std::fwrite(bytes.data(), 1, bytes.size(), f);
          std::fclose(f);
        }
      }
      ImageView vista(bytes.data(), W, H, ImageFormat::Lum);

      auto base = ReadBarcodes(vista, ReaderOptions().setFormats(BarcodeFormat::AllReadable));
      const bool okBase = !base.empty() && base[0].text() == c.esperado;

      // Como la camara: cuadros seguidos, con tope de tiempo por cuadro y la
      // ronda que devuelve el motor, hasta leer (o 12 cuadros).
      ml_codigo sal[4];
      ml_info info;
      int n = 0, cuadros = 0, ronda = 0, peorUs = 0, sumaUs = 0;
      std::string tiempos;
      for (; cuadros < 12 && n == 0; cuadros++) {
        n = ml_leer(bytes.data(), W, H, W, ML_PIXEL_LUMA, 0, 0, presupuesto, ronda, sal, 4, &info);
        ronda = info.siguiente_ronda;
        peorUs = std::max(peorUs, info.microsegundos);
        sumaUs += info.microsegundos;
        for (int p = 1; p < ML_PASOS; p++)
          if (info.tiempo_paso_us[p]) tiempos += " " + std::to_string(p) + ":" + std::to_string(info.tiempo_paso_us[p] / 1000);
        tiempos += " |";
      }
      bool okMotor = n > 0 && c.esperado == sal[0].texto;
      if (okMotor) {
        // Las esquinas deben caer sobre el codigo (centrado en la escena).
        float mx = 0, my = 0;
        for (int k = 0; k < 4; k++) mx += sal[0].x[k] / 4.0f, my += sal[0].y[k] / 4.0f;
        if (std::abs(mx - W / 2.0f) > 80 || std::abs(my - H / 2.0f) > 80) {
          std::printf("  esquinas fuera de lugar: centro (%.0f, %.0f)\n", mx, my);
          okMotor = false;
          peores++;
        }
      }

      totalBase += okBase;
      totalMotor += okMotor;
      if (okBase && !okMotor) peores++;
      std::printf("%-17s %-11s %-6s %-6s %-5d %-7d %6.1f  [%s ]\n", e.nombre, c.nombre, okBase ? "si" : "NO",
                  okMotor ? "si" : "NO", okMotor ? sal[0].paso : 0, okMotor ? cuadros : 0, peorUs / 1000.0,
                  tiempos.c_str());
      peorCuadro = std::max(peorCuadro, peorUs);
      if (okMotor) tiempoTotal += sumaUs;
    }
  }
  const int total = (int)(escenas.size() * codigos.size());
  std::printf("\nzxing solo: %d/%d   motor: %d/%d   cuadro mas lento: %.1f ms   tiempo total hasta leer: %.0f ms\n",
              totalBase, total, totalMotor, total, peorCuadro / 1000.0, tiempoTotal / 1000.0);
  return peores > 0 ? 1 : 0;
}
