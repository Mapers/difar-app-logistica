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

// [modo] de ml_leer (se combinan con |).
#define ML_MODO_TODOS 1           // todos los codigos (no cortar con el primero)
#define ML_MODO_CUADRO_COMPLETO 2 // todo el cuadro (si no, la zona central)
#define ML_MODO_SOLO_RAPIDO 4     // solo el paso rapido (camara sin disparar: ahorra bateria)
#define ML_MODO_INTERCALAR 8      // pasos dificiles 1 de cada 4 cuadros ([ronda]), con tope de 200 ms
#define ML_MODO_MOVIENDO 16       // el telefono se mueve rapido (giroscopio): se aplazan los pasos dificiles

// Paso que logro la lectura (para el registro y para afinar).
#define ML_PASO_RAPIDO 1     // zona central (75%), sin preparar
#define ML_PASO_COMPLETO 2   // todo el cuadro, rotado/invertido/sin ruido
#define ML_PASO_POCA_LUZ 3   // ecualizacion de contraste por zonas (CLAHE)
#define ML_PASO_REFLEJOS 4   // normalizacion local + enfoque (brillos, sombras)
#define ML_PASO_AMPLIADO 5   // zona central ampliada 2x + enfoque (chico/borroso)
#define ML_PASO_INVERTIDO 6  // negativo (impresion clara sobre fondo oscuro, 1D)
#define ML_PASO_ROTADO 7     // girado 45 grados (1D en angulo)
#define ML_PASO_DETECTOR 8   // OpenCV ubico el codigo; recorte enderezado, sin preparar
#define ML_PASO_DETECTOR_PREP 9 // idem, recorte con contraste ecualizado
#define ML_PASO_GRIS 10      // recorte de OpenCV leido en tonos de gris (EAN/UPC borroso o movido)
#define ML_PASO_RED 11       // recorte de OpenCV leido por la red neuronal propia (EAN-13/UPC-A)
#define ML_PASO_RESTAURADO 12 // recorte de OpenCV con las barras restauradas por la red propia, leido por zxing (todos los 1D)
#define ML_PASOS 13

typedef struct {
  int32_t formato;      // uno de ML_* (0 si no esta en la lista)
  int32_t paso;         // ML_PASO_*
  int32_t invertido;    // 1 si era claro sobre oscuro
  int32_t x[4];         // esquinas en pixeles de la imagen de entrada
  int32_t y[4];
  char nombre_formato[32];
  char texto[1024];
  int32_t sin_leer;     // 1: OpenCV ve un codigo ahi pero no se pudo leer (texto vacio)
  int32_t verificado;   // EAN/UPC contra los tonos de gris: 1 calzan, -1 no calzan, 0 no se sabe
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
  int32_t ilegibles;       // simbolos encontrados que fallaron la verificacion (codigo danado)
  int32_t hilos;           // hilos usados en los pasos dificiles
  int32_t regiones;        // codigos 1D que ubico el detector de OpenCV (-1 = apagado)
} ml_info;

// Hilos para los pasos dificiles: 0 = segun los nucleos (por defecto, en
// paralelo), 1 = uno tras otro repartidos entre cuadros con [ronda].
FFI_PLUGIN_EXPORT void ml_configurar(int32_t hilos);

// Detector de OpenCV (ubica cada codigo 1D, lo recorta y endereza): 1 = si,
// 0 = no. Solo si la biblioteca se compilo con OpenCV (ML_CON_OPENCV).
FFI_PLUGIN_EXPORT void ml_configurar_detector(int32_t activo);

// 1 si la biblioteca se compilo con OpenCV (detector de codigos 1D).
FFI_PLUGIN_EXPORT int32_t ml_con_opencv(void);

// Lee los codigos de un cuadro. Devuelve cuantos escribio en [salida].
// [modo]: ML_MODO_* combinados. Con ML_MODO_TODOS junta lo que lea cada
// paso; si no, corta con el primero. Los pasos que preparan la imagen
// exigen que mas lineas de barrido coincidan (evita lecturas falsas).
// Primero el paso rapido; si no alcanza, los dificiles. En paralelo (por
// defecto) corren todos a la vez en varios hilos. Uno tras otro (ver
// ml_configurar): [presupuesto_us] es el tope por cuadro (0 = sin limite) y
// [ronda] el numero de cuadro, para seguir donde quedo el anterior.
FFI_PLUGIN_EXPORT int32_t ml_leer(const uint8_t* datos, int32_t ancho, int32_t alto, int32_t bytes_por_fila,
                                  int32_t formato_pixel, int32_t formatos, int32_t modo,
                                  int32_t presupuesto_us, int32_t ronda, ml_codigo* salida,
                                  int32_t max_salida, ml_info* info);

#ifdef __cplusplus
}
#endif
