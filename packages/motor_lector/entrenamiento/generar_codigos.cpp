// Vuelca codigos 1D al azar (formato, texto, modulos 0/1) con el escritor de zxing.
#include "BitMatrix.h"
#include "MultiFormatWriter.h"
#include "BarcodeFormat.h"
#include <cstdio>
#include <random>
#include <string>
using namespace ZXing;
int main(int argc, char** argv) {
  const int n = atoi(argv[1]);
  std::mt19937 rng(atoi(argv[2]));
  auto dig = [&](int k) { std::string s; for (int i = 0; i < k; i++) s += char('0' + rng() % 10); return s; };
  auto alfa = [&](int k) { const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-. "; std::string s; for (int i = 0; i < k; i++) s += a[rng() % 39]; return s; };
  int hechos = 0;
  while (hechos < n) {
    const int t = rng() % 10;
    BarcodeFormat f; std::string txt;
    switch (t) {
      case 0: case 1: f = BarcodeFormat::EAN13; txt = dig(12); break;
      case 2: f = BarcodeFormat::EAN8; txt = dig(7); break;
      case 3: f = BarcodeFormat::UPCA; txt = dig(11); break;
      case 4: case 5: f = BarcodeFormat::Code128; txt = (rng() % 2) ? dig(6 + rng() % 20) : alfa(4 + rng() % 14); break;
      case 6: f = BarcodeFormat::ITF; txt = dig(2 * (3 + rng() % 5)); break;
      case 7: f = BarcodeFormat::Code39; txt = alfa(4 + rng() % 10); break;
      case 8: f = BarcodeFormat::Codabar; txt = "A" + dig(6 + rng() % 10) + "B"; break;
      default: f = BarcodeFormat::Code93; txt = alfa(4 + rng() % 10); break;
    }
    try {
      auto m = MultiFormatWriter(f).setMargin(0).encode(txt, 1, 1);
      std::string bits;
      for (int x = 0; x < m.width(); x++) bits += m.get(x, 0) ? '1' : '0';
      if (bits.size() > 340) continue;
      printf("%s\t%s\t%s\n", ToString(f).c_str(), txt.c_str(), bits.c_str());
      hechos++;
    } catch (...) {}
  }
}
