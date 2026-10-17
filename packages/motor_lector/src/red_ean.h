// Red neuronal propia para leer EAN-13 / UPC-A borrosos o movidos (como el
// "decodificador neuronal" de los SDK comerciales, pero entrenada por
// nosotros con perfiles sinteticos: desenfoque, movimiento, perspectiva,
// tinta corrida, luz despareja, reflejos). Lee el perfil de tonos de gris del
// recorte enderezado (400 muestras) y da los 13 digitos y si es un EAN.
// Inferencia propia en C++ (sin librerias): ~6 millones de operaciones.
#pragma once

#include "preparar.h"

#include <string>

namespace red {

struct Resultado {
  std::string texto; // 13 digitos
  float esEan = 0;   // 0..1
  float minima = 0;  // probabilidad del digito menos seguro
  float margen = 0;  // diferencia (log) con la segunda combinacion valida
};

// [img]: recorte con las barras verticales, en cualquier sentido. Devuelve
// true si la lectura pasa los umbrales de confianza y el digito verificador.
bool leerEan(const prep::Gris& img, Resultado& r);

// Probabilidades crudas de un perfil de 400 muestras (para las pruebas).
// salida: 13 x 10 probabilidades y luego la de "es un EAN".
void inferir(const float* perfil400, float* salida131);

} // namespace red
