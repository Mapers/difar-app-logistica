// Ubicacion de codigos 1D con OpenCV (cv::barcode::BarcodeDetector): encuentra
// todos los codigos del cuadro con su angulo, para recortarlos, enderezarlos y
// decodificar cada recorte por separado (y en paralelo) con zxing.
#pragma once

#include "preparar.h"

#include <array>
#include <vector>

namespace det {

// 4 esquinas (x0,y0,...,x3,y3) en pixeles de la imagen de entrada.
using Cuadrilatero = std::array<float, 8>;

// Busca codigos 1D. [px] es luminancia con [fila] bytes por fila.
std::vector<Cuadrilatero> detectar(const uint8_t* px, int ancho, int alto, int fila);

// Recorte enderezado (barras verticales, codigo horizontal) con margen para
// la zona blanca, y la transformacion del recorte a la imagen de entrada:
// X = a*x + b*y + tx ; Y = c*x + d*y + ty.
struct Recorte {
  prep::Gris img;
  float a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;
};

Recorte enderezar(const uint8_t* px, int ancho, int alto, int fila, const Cuadrilatero& q);

// Ecualizacion de contraste por zonas (CLAHE de OpenCV) para un recorte.
prep::Gris clahe(const prep::Gris& img);

} // namespace det
