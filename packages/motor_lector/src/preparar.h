// Preparacion de imagen para codigos dificiles. Todo trabaja sobre
// luminancia (1 byte por pixel) y devuelve imagenes nuevas.
#pragma once

#include "ImageView.h"

#include <cstdint>
#include <vector>

namespace prep {

struct Gris {
  int ancho = 0, alto = 0;
  std::vector<uint8_t> px;
  ZXing::ImageView vista() const { return {px.data(), ancho, alto, ZXing::ImageFormat::Lum}; }
};

struct Estadistica {
  int brillo;    // promedio 0..255
  int contraste; // desviacion estandar
  int quemados;  // % de pixeles >= 250
  int nitidez;   // promedio del |laplaciano|: bajo = desenfocado o movido
};

// Mide la zona central (la mitad del cuadro), salteando pixeles para ser rapido.
Estadistica medir(const uint8_t* px, int ancho, int alto, int fila);

Gris deBgra(const uint8_t* bgra, int ancho, int alto, int fila);

// CLAHE: ecualiza el histograma por zonas ([zx] x [zy]) limitando el
// contraste ([limite]) para no inflar el ruido. Saca codigos de la oscuridad
// y de las sombras sin quemar lo que ya estaba bien.
Gris clahe(const uint8_t* px, int ancho, int alto, int fila, int zx, int zy, float limite);

// Cada pixel contra el promedio y la desviacion de su vecindario de radio
// [radio]: quita gradientes de luz, sombras y el velo de los reflejos.
Gris normalizarLocal(const uint8_t* px, int ancho, int alto, int fila, int radio);

// Para codigos 1D: detecta si las barras estan verticales u horizontales
// (comparando bordes en x y en y), promedia a lo largo de las barras (quita
// ruido, granos y arrugas sin borrar las barras) y normaliza localmente.
// Saca codigos de bolsas arrugadas, sombras y reflejos parciales.
Gris afinar1D(const uint8_t* px, int ancho, int alto, int fila, int radioSuave, int radioNorm);

// Mascara de enfoque (unsharp mask) 3x3: realza los bordes de las barras.
Gris enfocar(const Gris& img, float cantidad);

// Negativo: zxing no prueba la version invertida en codigos 1D (solo en 2D),
// y en botellas y cajas oscuras es comun la impresion clara sobre fondo oscuro.
Gris invertir(const uint8_t* px, int ancho, int alto, int fila);

// Gira 45 grados (bilineal). zxing lee 1D solo cada 90 grados; con 45 mas
// queda cubierto cualquier angulo. La imagen nueva es un cuadrado de lado
// (ancho + alto) / raiz(2); el centro queda en el centro.
Gris rotar45(const uint8_t* px, int ancho, int alto, int fila);

// Ampliacion bilineal 2x, para codigos chicos o lejanos.
Gris ampliar2x(const uint8_t* px, int ancho, int alto, int fila);

} // namespace prep
