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
#include <algorithm>
#include <functional>
#include <set>
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
  int peores = 0, totalBase = 0, totalMotor = 0, peorCuadro = 0, falsos = 0;
  double tiempoTotal = 0; // suma, en los leidos, del tiempo de todos los cuadros hasta leer
  const int hilos = std::getenv("BANCO_HILOS") ? std::atoi(std::getenv("BANCO_HILOS")) : 0;
  ml_configurar(hilos);
  const int detector = std::getenv("BANCO_DETECTOR") ? std::atoi(std::getenv("BANCO_DETECTOR")) : 1;
  ml_configurar_detector(detector);
  std::printf("detector OpenCV: %s\n", detector ? "si" : "no");
  // BANCO_INTERCALAR=1: como la camara en vivo (pasos dificiles 1 de cada 4 cuadros).
  const int modoUno = std::getenv("BANCO_INTERCALAR") && std::atoi(std::getenv("BANCO_INTERCALAR")) ? ML_MODO_INTERCALAR : 0;
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
      for (; cuadros < 12 && (n == 0 || sal[0].sin_leer); cuadros++) {
        n = ml_leer(bytes.data(), W, H, W, ML_PIXEL_LUMA, 0, modoUno, presupuesto, ronda, sal, 4, &info);
        ronda = info.siguiente_ronda;
        peorUs = std::max(peorUs, info.microsegundos);
        sumaUs += info.microsegundos;
        for (int p = 1; p < ML_PASOS; p++)
          if (info.tiempo_paso_us[p]) tiempos += " " + std::to_string(p) + ":" + std::to_string(info.tiempo_paso_us[p] / 1000);
        tiempos += " |";
      }
      int reales = 0;
      for (int k = 0; k < n; k++) reales += !sal[k].sin_leer;
      bool okMotor = reales > 0 && c.esperado == sal[0].texto;
      // Lectura falsa: devolvio un texto que no es el del codigo. Es el peor
      // error (cuenta un producto que no esta): el banco falla si hay alguna.
      for (int k = 0; k < n; k++)
        if (!sal[k].sin_leer && c.esperado != sal[k].texto) {
          std::printf("  LECTURA FALSA: '%s' (paso %d) en vez de '%s'\n", sal[k].texto, sal[k].paso, c.esperado.c_str());
          falsos++;
        }
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

  // --- Muchos codigos a la vez: 20 EAN-13 en un cuadro 1920x1080, cada uno
  // girado un poco distinto (cajas en un pallet). Como el conteo multiple.
  {
    constexpr int GW = 1920, GH = 1080;
    const bool danados = std::getenv("BANCO_DANADOS") && std::atoi(std::getenv("BANCO_DANADOS"));
    std::vector<float> img(GW * GH);
    std::mt19937 rng(11);
    std::normal_distribution<float> ruido(0, 5);
    for (int i = 0; i < GW * GH; i++) img[i] = 110 + ruido(rng);
    std::vector<std::string> esperados;
    for (int k = 0; k < 20; k++) {
      // 10 productos distintos, 2 cajas de cada uno: se deben contar las 20.
      std::string base = "77501820" + std::to_string(1000 + (k % 10) * 37);
      base = base.substr(0, 12);
      int suma = 0;
      for (int i = 0; i < 12; i++) suma += (base[i] - '0') * (i % 2 ? 3 : 1);
      esperados.push_back(base + char('0' + (10 - suma % 10) % 10));
      auto bits = MultiFormatWriter(BarcodeFormat::EAN13).setMargin(0).encode(base, 200, 90);
      const int cx = 200 + (k % 5) * 380, cy = 150 + (k / 5) * 260;
      const float ang = ((k * 7) % 21 - 10) * 3.14159f / 180; // -10..10 grados
      const float co = std::cos(ang), si = std::sin(ang);
      const int bw = bits.width(), bh = bits.height();
      for (int y = -bh / 2 - 25; y < bh / 2 + 25; y++)
        for (int x = -bw / 2 - 30; x < bw / 2 + 30; x++) {
          const int X = (int)(cx + co * x - si * y), Y = (int)(cy + si * x + co * y);
          if (X < 0 || Y < 0 || X >= GW || Y >= GH) continue;
          const int bx = x + bw / 2, by = y + bh / 2;
          const bool negro = bx >= 0 && by >= 0 && bx < bw && by < bh && bits.get(bx, by);
          // BANCO_DANADOS=1: las cajas 3 y 14 con una mancha que tapa el centro
          // de las barras (no se pueden leer): deben salir como "sin leer".
          // Dano realista: rayas blancas finas cruzando las barras (etiqueta
          // raspada). Se siguen viendo barras (OpenCV ubica el codigo) pero
          // faltan pedazos de cada barra en todas las lineas.
          const bool raspado = danados && (k == 3 || k == 14) && bx >= 0 && bx < bw && ((bx / 3) % 4 == 0);
          img[Y * GW + X] = (raspado ? 235 : (negro ? 20 : 235)) + ruido(rng);
        }
    }
    std::vector<uint8_t> b(GW * GH);
    for (int i = 0; i < GW * GH; i++) b[i] = (uint8_t)std::clamp(img[i], 0.0f, 255.0f);
    if (std::getenv("BANCO_PGM")) {
      const std::string ruta = std::string(std::getenv("BANCO_PGM")) + "/veinte.pgm";
      if (FILE* f = std::fopen(ruta.c_str(), "wb")) {
        std::fprintf(f, "P5 %d %d 255\n", GW, GH);
        std::fwrite(b.data(), 1, b.size(), f);
        std::fclose(f);
      }
    }
    std::vector<ml_codigo> sal(64);
    ml_info info;
    std::set<std::string> leidos;
    int cuadros = 0, ms = 0, falsosV = 0, instancias = 0, sinLeer = 0, verif20 = 0;
    for (; cuadros < 10 && instancias < 20; cuadros++) {
      instancias = 0;
      sinLeer = 0;
      const int n = ml_leer(b.data(), GW, GH, GW, ML_PIXEL_LUMA, 0, ML_MODO_TODOS | ML_MODO_CUADRO_COMPLETO, 0, cuadros,
                            sal.data(), 64, &info);
      ms += info.microsegundos / 1000;
      for (int k = 0; k < n; k++) {
        if (sal[k].sin_leer) {
          sinLeer++;
          continue;
        }
        if (std::find(esperados.begin(), esperados.end(), sal[k].texto) == esperados.end()) {
          std::printf("  LECTURA FALSA (20 codigos): '%s' paso %d\n", sal[k].texto, sal[k].paso);
          falsosV++;
        } else {
          leidos.insert(sal[k].texto);
          instancias++;
          verif20 += sal[k].verificado;
        }
      }
      std::string tiempos;
      for (int p = 1; p < ML_PASOS; p++)
        if (info.tiempo_paso_us[p]) tiempos += " " + std::to_string(p) + ":" + std::to_string(info.tiempo_paso_us[p] / 1000);
      std::printf("  20 cajas, cuadro %d: %d unidades (%zu productos), %d sin leer, %d ms, detector ubico %d [%s ]\n",
                  cuadros + 1, instancias, leidos.size(), sinLeer, info.microsegundos / 1000, info.regiones, tiempos.c_str());
    }
    std::printf("20 CAJAS (10 productos x 2): %d/20 unidades, %zu/10 productos, en %d cuadros, %d ms, falsos %d, "
                "lecturas verificadas %d\n", instancias, leidos.size(), cuadros, ms, falsosV, verif20);
    falsos += falsosV;
  }

  // --- Imagen movida: EAN-13 con desenfoque de movimiento a lo ancho del
  // codigo (lo peor: borronea las barras entre si), como al pasar el
  // telefono rapido o con exposicion larga. Cuenta lo que lee zxing solo, el
  // motor, y cuantas lecturas salieron del lector en tonos de gris.
  {
    const char* eans[] = {"775018200012", "775360881571", "205000061068", "775846700087", "750103131130"};
    auto conVerificador = [](const std::string& d) {
      int s = 0;
      for (int i = 0; i < 12; i++) s += (d[i] - '0') * (i % 2 ? 3 : 1);
      return d + (char)('0' + (10 - s % 10) % 10);
    };
    int okZx = 0, okMotor = 0, okGris = 0, casos = 0, falsosM = 0, verificados = 0;
    std::string tabla;
    for (float escala : {0.8f, 1.0f, 1.3f}) {
      tabla += "  escala " + std::to_string(escala).substr(0, 3) + " (" +
               std::to_string(escala * 300 / 95).substr(0, 3) + " px/barra):";
      for (int largo : {0, 3, 5, 7, 9, 11, 13, 15}) {
        int zx = 0, mo = 0, gr = 0;
        for (int e = 0; e < 5; e++) {
          const Codigo c{"EAN-13", BarcodeFormat::EAN13, eans[e], conVerificador(eans[e]), 300, 140};
          Img img = escena(c, escala);
          if (largo > 0) {
            Img t(img.size());
            for (int y = 0; y < H; y++)
              for (int x = 0; x < W; x++) {
                float acum = 0;
                int n = 0;
                for (int d = -largo / 2; d <= largo / 2; d++) {
                  const int xx = std::clamp(x + d, 0, W - 1);
                  acum += img[y * W + xx];
                  n++;
                }
                t[y * W + x] = acum / n;
              }
            img.swap(t);
          }
          ruido(img, 4, 11 + e);
          const auto b = aBytes(img);
          casos++;
          const auto base = ReadBarcodes(ImageView(b.data(), W, H, ImageFormat::Lum), ReaderOptions().setFormats(BarcodeFormat::EAN13));
          if (!base.empty() && base[0].text() == c.esperado) zx++;
          ml_codigo sal[8];
          ml_info info;
          bool leido = false, deGris = false;
          for (int cuadro = 0; cuadro < 2 && !leido; cuadro++) {
            const int n = ml_leer(b.data(), W, H, W, ML_PIXEL_LUMA, 0, ML_MODO_TODOS, 0, cuadro, sal, 8, &info);
            for (int k = 0; k < n; k++) {
              if (sal[k].sin_leer) continue;
              if (c.esperado == sal[k].texto) {
                leido = true;
                verificados += sal[k].verificado;
                deGris = deGris || sal[k].paso == ML_PASO_GRIS;
              } else {
                std::printf("  LECTURA FALSA (movido %d px): '%s' en vez de %s, paso %d\n", largo, sal[k].texto,
                            c.esperado.c_str(), sal[k].paso);
                falsosM++;
              }
            }
          }
          mo += leido;
          gr += deGris;
        }
        okZx += zx;
        okMotor += mo;
        okGris += gr;
        tabla += "  " + std::to_string(largo) + "px:" + std::to_string(zx) + "/" + std::to_string(mo) +
                 (gr ? "(g" + std::to_string(gr) + ")" : "");
      }
      tabla += "\n";
    }
    std::printf("MOVIDO (desenfoque horizontal; zxing/motor de 5, g = por tonos de gris):\n%s", tabla.c_str());
    std::printf("MOVIDO: zxing solo %d/%d, motor %d/%d (%d por tonos de gris, %d lecturas verificadas), falsos %d\n", okZx,
                casos, okMotor, casos, okGris, verificados, falsosM);
    falsos += falsosM;
  }

  // --- Sin codigos: texto impreso y rayas (carton corrugado, rejillas). Toda
  // lectura es falsa. Con esfuerzo (boton presionado), 20 cuadros.
  {
    std::vector<float> img(W * H, 200);
    std::mt19937 rng(5);
    std::uniform_int_distribution<int> u(0, 1000);
    // "Texto": renglones de palabras hechas de trazos verticales de ancho variable.
    for (int renglon = 0; renglon < 14; renglon++) {
      const int y0 = 30 + renglon * 48;
      for (int x = 20; x < W / 2;) {
        const int palabra = 20 + u(rng) % 80;
        for (int p = 0; p < palabra; p += 2 + u(rng) % 5)
          for (int y = y0; y < y0 + 18 + u(rng) % 6; y++)
            for (int t = 0; t < 1 + u(rng) % 3; t++)
              if (x + p + t < W) img[y * W + x + p + t] = 30;
        x += palabra + 12;
      }
    }
    // Rayas regulares y casi regulares (corrugado, rejilla, tela).
    for (int y = 0; y < H; y++)
      for (int x = W / 2; x < W; x++) {
        const float periodo = 6 + 4 * std::sin(y * 0.01f);
        img[y * W + x] = 128 + 100 * std::sin(x * 6.2832f / periodo) + (u(rng) % 20);
      }
    const auto b = aBytes(img);
    ml_codigo sal[8];
    ml_info info;
    int falsosT = 0;
    for (int c = 0; c < 20; c++) {
      const int n = ml_leer(b.data(), W, H, W, ML_PIXEL_LUMA, 0, ML_MODO_TODOS, 0, c, sal, 8, &info);
      for (int k = 0; k < n; k++) {
        if (sal[k].sin_leer) continue;
        std::printf("  LECTURA FALSA (texto/rayas): '%s' %s paso %d\n", sal[k].texto, sal[k].nombre_formato, sal[k].paso);
        falsosT++;
      }
    }
    std::printf("TEXTO Y RAYAS (sin codigos): %d lecturas falsas en 20 cuadros\n", falsosT);
    falsos += falsosT;
  }

  std::printf("\nzxing solo: %d/%d   motor: %d/%d   cuadro mas lento: %.1f ms   tiempo total hasta leer: %.0f ms\n",
              totalBase, total, totalMotor, total, peorCuadro / 1000.0, tiempoTotal / 1000.0);
  std::printf("lecturas falsas: %d\n", falsos);
  return peores > 0 || falsos > 0 ? 1 : 0;
}
