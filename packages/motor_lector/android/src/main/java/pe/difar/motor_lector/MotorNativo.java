package pe.difar.motor_lector;

import java.nio.ByteBuffer;

/** Motor C++ llamado desde el analizador de la camara (sin pasar por Dart). */
final class MotorNativo {
  static {
    System.loadLibrary("motor_lector");
  }

  private MotorNativo() {}

  /**
   * Lee el plano Y (luminancia) de un cuadro. Devuelve el resultado como JSON en UTF-8:
   * {"c":[codigos],"i":{medicion}}. Null si el buffer no es directo o le faltan bytes.
   */
  static native byte[] leer(
      ByteBuffer plano, int ancho, int alto, int fila, int formatos, int modo, int presupuestoUs, int ronda);
}
