// Lector de EAN-13 / UPC-A / EAN-8 sobre tonos de gris, para codigos
// borrosos o movidos (donde zxing falla porque primero pasa la imagen a
// blanco y negro). Promedia las filas del centro del codigo y compara el
// perfil contra el dibujo que deberia tener cada digito ya desenfocado, con
// el desenfoque y el ancho de barra estimados de las guardas. Los digitos se
// eligen todos juntos para que cumplan el digito verificador (y en EAN-13 la
// paridad que da el primer digito), y solo se acepta si el resultado es
// claro: es lo que hacen los SDK comerciales con imagen borrosa.
#pragma once

#include "preparar.h"

#include <string>

namespace gris {

struct Resultado {
  std::string texto;
  bool ean8 = false;
  float x0 = 0, x1 = 0; // extremos del codigo en el recorte (pixeles)
  float y0 = 0, y1 = 0; // filas usadas
  float calidad = 0;    // ajuste promedio (0..1, 1 = perfecto)
};

// [img]: recorte con las barras verticales (codigo horizontal), en
// cualquiera de los dos sentidos. [ean13] / [ean8]: que buscar.
bool leerEan(const prep::Gris& img, bool ean13, bool ean8, Resultado& r);

// Revisa una lectura de EAN-13 (13 digitos) o EAN-8 (8) de otro lector
// contra los tonos de gris del recorte: -1 = los digitos no calzan con la
// imagen (lectura falsa), 1 = calzan, 0 = no se puede saber.
int verificarEan(const prep::Gris& img, const std::string& texto);

} // namespace gris
