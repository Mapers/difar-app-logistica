// Puente JNI para la camara nativa (Android): el analizador de CameraX le pasa
// el plano Y del cuadro directo al motor, sin copiarlo a Dart. El resultado
// vuelve como JSON (bytes UTF-8) y llega a Dart por un EventChannel.
#include "motor_lector.h"

#include <jni.h>

#include <cstdio>
#include <string>
#include <vector>

namespace {

void agregarTexto(std::string& s, const char* t) {
  s += '"';
  for (const unsigned char* p = (const unsigned char*)t; *p; p++) {
    const unsigned char c = *p;
    if (c == '"' || c == '\\') {
      s += '\\';
      s += (char)c;
    } else if (c < 0x20) {
      char u[8];
      std::snprintf(u, sizeof u, "\\u%04x", c);
      s += u;
    } else {
      s += (char)c; // UTF-8 tal cual; Java reemplaza lo invalido al decodificar
    }
  }
  s += '"';
}

void agregarNumero(std::string& s, const char* clave, long v) {
  s += '"';
  s += clave;
  s += "\":";
  s += std::to_string(v);
  s += ',';
}

} // namespace

extern "C" JNIEXPORT jbyteArray JNICALL Java_pe_difar_motor_1lector_MotorNativo_leer(
    JNIEnv* env, jclass, jobject plano, jint ancho, jint alto, jint fila, jint formatos, jint modo,
    jint presupuesto, jint ronda) {
  const auto* px = (const uint8_t*)env->GetDirectBufferAddress(plano);
  if (px == nullptr) return nullptr;
  // El ultimo renglon del plano puede venir sin el relleno de la fila.
  const jlong capacidad = env->GetDirectBufferCapacity(plano);
  if (capacidad < (jlong)fila * (alto - 1) + ancho) return nullptr;

  thread_local std::vector<ml_codigo> salida(64);
  ml_info info{};
  const int n = ml_leer(px, ancho, alto, fila, ML_PIXEL_LUMA, formatos, modo, presupuesto, ronda, salida.data(),
                        (int)salida.size(), &info);

  std::string s;
  s.reserve(512 + n * 256);
  s += "{\"c\":[";
  for (int i = 0; i < n; i++) {
    const ml_codigo& c = salida[i];
    if (i) s += ',';
    s += "{\"t\":";
    agregarTexto(s, c.texto);
    s += ",\"f\":";
    agregarTexto(s, c.nombre_formato);
    s += ',';
    agregarNumero(s, "b", c.formato);
    agregarNumero(s, "p", c.paso);
    agregarNumero(s, "i", c.invertido);
    agregarNumero(s, "s", c.sin_leer);
    agregarNumero(s, "v", c.verificado);
    s += "\"x\":[";
    for (int k = 0; k < 4; k++) s += std::to_string(c.x[k]) + (k < 3 ? "," : "");
    s += "],\"y\":[";
    for (int k = 0; k < 4; k++) s += std::to_string(c.y[k]) + (k < 3 ? "," : "");
    s += "]}";
  }
  s += "],\"i\":{";
  agregarNumero(s, "brillo", info.brillo);
  agregarNumero(s, "contraste", info.contraste);
  agregarNumero(s, "quemados", info.quemados);
  agregarNumero(s, "linterna", info.sugerir_linterna);
  agregarNumero(s, "pasos", info.pasos);
  agregarNumero(s, "ronda", info.siguiente_ronda);
  agregarNumero(s, "us", info.microsegundos);
  agregarNumero(s, "nitidez", info.nitidez);
  agregarNumero(s, "ilegibles", info.ilegibles);
  agregarNumero(s, "hilos", info.hilos);
  agregarNumero(s, "regiones", info.regiones);
  s += "\"tp\":[";
  for (int k = 0; k < ML_PASOS; k++) s += std::to_string(info.tiempo_paso_us[k]) + (k < ML_PASOS - 1 ? "," : "");
  s += "]}}";

  jbyteArray r = env->NewByteArray((jsize)s.size());
  if (r != nullptr) env->SetByteArrayRegion(r, 0, (jsize)s.size(), (const jbyte*)s.data());
  return r;
}
