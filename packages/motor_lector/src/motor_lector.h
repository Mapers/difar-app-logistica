// Motor de lectura de codigos de barras de DIFAR Logistica.
//
// Lee cuadros de la camara con zxing-cpp aplicando, por pasos y dentro de un
// tiempo maximo, distintas preparaciones de la imagen para codigos dificiles:
// poca luz, sombras, reflejos (botellas, bolsas), colores invertidos,
// codigos chicos o borrosos. Corta en cuanto lee algo.
#pragma once

#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Formato de los pixeles de entrada.
#define ML_PIXEL_LUMA 0 // 1 byte por pixel (plano Y de YUV420 en Android)
#define ML_PIXEL_BGRA 1 // 4 bytes por pixel (iOS)

// Mascara de formatos a buscar (0 = todos). Menos formatos = mas rapido.
#define ML_EAN13 (1 << 0)
#define ML_EAN8 (1 << 1)
#define ML_UPCA (1 << 2)
#define ML_UPCE (1 << 3)
#define ML_CODE128 (1 << 4)
#define ML_CODE39 (1 << 5)
#define ML_CODE93 (1 << 6)
#define ML_ITF (1 << 7)
#define ML_CODABAR (1 << 8)
#define ML_DATABAR (1 << 9)
#define ML_QR (1 << 10)
#define ML_DATAMATRIX (1 << 11)
#define ML_PDF417 (1 << 12)
#define ML_AZTEC (1 << 13)
#define ML_MICROQR (1 << 14)

// Paso que logro la lectura (para el registro y para afinar).
#define ML_PASO_RAPIDO 1     // zona central (75%), sin preparar
#define ML_PASO_COMPLETO 2   // todo el cuadro, rotado/invertido/sin ruido
#define ML_PASO_POCA_LUZ 3   // ecualizacion de contraste por zonas (CLAHE)
#define ML_PASO_REFLEJOS 4   // normalizacion local + enfoque (brillos, sombras)
#define ML_PASO_AMPLIADO 5   // zona central ampliada 2x + enfoque (chico/borroso)
#define ML_PASO_INVERTIDO 6  // negativo (impresion clara sobre fondo oscuro, 1D)
#define ML_PASO_ROTADO 7     // girado 45 grados (1D en angulo)
#define ML_PASOS 8

typedef struct {
  int32_t formato;      // uno de ML_* (0 si no esta en la lista)
  int32_t paso;         // ML_PASO_*
  int32_t invertido;    // 1 si era claro sobre oscuro
  int32_t x[4];         // esquinas en pixeles de la imagen de entrada
  int32_t y[4];
  char nombre_formato[32];
  char texto[1024];
} ml_codigo;

typedef struct {
  int32_t brillo;          // 0..255, promedio de la zona central
  int32_t contraste;       // desviacion estandar de la zona central
  int32_t quemados;        // % de pixeles casi blancos (reflejos)
  int32_t sugerir_linterna;// 1 si hay poca luz
  int32_t pasos;           // cuantos pasos se probaron
  int32_t siguiente_ronda; // valor de [ronda] para el proximo cuadro
  int32_t microsegundos;   // tiempo total
  int32_t tiempo_paso_us[ML_PASOS]; // tiempo de cada paso (indice = ML_PASO_*), 0 si no se hizo
  int32_t nitidez;         // promedio del |laplaciano| del centro: bajo = desenfocado o movido
} ml_info;

// Lee los codigos de un cuadro. Devuelve cuantos escribio en [salida].
// [multiple] != 0: busca todos los codigos del cuadro (conteo multiple) y
// junta lo que lea cada paso; si no, corta con el primero.
// [presupuesto_us]: tiempo maximo aproximado por cuadro (0 = sin limite).
// El paso rapido siempre se hace; los dificiles, mientras alcance el tiempo.
// [ronda]: numero de cuadro. Los pasos dificiles se reparten entre cuadros:
// cada uno empieza donde quedo el anterior, asi ningun cuadro tarda mucho y
// en pocos cuadros se prueban todos.
FFI_PLUGIN_EXPORT int32_t ml_leer(const uint8_t* datos, int32_t ancho, int32_t alto, int32_t bytes_por_fila,
                                  int32_t formato_pixel, int32_t formatos, int32_t multiple,
                                  int32_t presupuesto_us, int32_t ronda, ml_codigo* salida,
                                  int32_t max_salida, ml_info* info);

#ifdef __cplusplus
}
#endif
