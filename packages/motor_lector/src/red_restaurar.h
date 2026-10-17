// Red neuronal propia de restauracion 1D (quita el desenfoque y el
// movimiento): del perfil de tonos de gris de un recorte enderezado saca las
// barras nitidas, y esas barras las lee zxing con sus propios controles
// (digito verificador, checksum). Sirve para todos los 1D: EAN/UPC, Code 128,
// Code 39/93, ITF, Codabar. Entrenada por nosotros con perfiles sinteticos.
#pragma once

#include "preparar.h"

#include <vector>

namespace red {

constexpr int kLargoRestaurar = 1024;

// Barras nitidas (1 = barra) en kLargoRestaurar muestras a lo ancho del
// recorte. false si la red no esta disponible.
bool restaurar(const prep::Gris& img, std::vector<uint8_t>& barras);

// Probabilidad de barra en cada muestra de un perfil de 1024 (para las pruebas).
void inferirRestaurar(const float* perfil1024, float* prob1024);

} // namespace red
