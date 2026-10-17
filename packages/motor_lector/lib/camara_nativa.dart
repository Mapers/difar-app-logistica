/// Camara nativa (Android, CameraX): la vista previa llega como textura y
/// cada cuadro va directo al motor C++ en Java/JNI, sin pasar los pixeles por
/// Dart. Aqui llegan solo los resultados.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'motor_lector.dart';

/// Lo que devuelve [CamaraNativa.iniciar].
class DatosCamara {
  DatosCamara(Map<Object?, Object?> m)
      : textura = (m['textura'] as num).toInt(),
        giroListo = m['giroListo'] == true,
        giroVista = (m['giroVista'] as num).toInt(),
        previaAncho = (m['previaAncho'] as num).toInt(),
        previaAlto = (m['previaAlto'] as num).toInt(),
        giroSensor = (m['giroSensor'] as num).toInt(),
        zoomMin = (m['zoomMin'] as num).toDouble(),
        zoomMax = (m['zoomMax'] as num).toDouble(),
        exposicionManual = m['exposicionManual'] == true,
        fps = (m['fps'] as num?)?.toInt() ?? 30,
        isoMax = (m['isoMax'] as num?)?.toInt() ?? 0,
        diagnostico = (m['diagnostico'] as String?) ?? '',
        nucleos = (m['nucleos'] as num).toInt();

  /// Id de la textura de Flutter con la vista previa.
  final int textura;

  /// La textura ya viene girada (si no, hay que girarla [giroVista] grados).
  final bool giroListo;
  final int giroVista;

  /// Tamano de la vista previa, en la orientacion del sensor.
  final int previaAncho, previaAlto;
  final int giroSensor;
  final double zoomMin, zoomMax;

  /// La camara declara exposicion manual (MANUAL_SENSOR). Si no la declara
  /// igual se prueba: ver [CuadroNativo.modoExposicion].
  final bool exposicionManual;

  /// Cuadros por segundo fijos que se pidieron (60 si el sensor puede).
  final int fps;

  /// ISO maximo del sensor (0 si no se sabe).
  final int isoMax;

  /// Nivel de la camara, capacidades y rangos (para el registro).
  final String diagnostico;
  final int nucleos;
}

/// Un cuadro analizado por el motor dentro de la camara nativa.
class CuadroNativo {
  CuadroNativo._(this.resultado, Map<String, dynamic> m)
      : ancho = m['ancho'] as int,
        alto = m['alto'] as int,
        fila = m['fila'] as int,
        giro = m['giro'] as int,
        analizados = m['analizados'] as int,
        sensor = m['sensor'] as int,
        msMotor = m['msMotor'] as int,
        edadMs = m['edad'] as int,
        velocidadGiro = (m['giroRad'] as num?)?.toDouble() ?? 0,
        exposicionNs = (m['exp'] as int?) ?? 0,
        iso = (m['iso'] as int?) ?? 0,
        modoExposicion = (m['modoExp'] as String?) ?? '?';

  factory CuadroNativo.desdeJson(String texto) {
    final m = jsonDecode(texto) as Map<String, dynamic>;
    return CuadroNativo._(resultadoDesdeJson(m['m'] as Map<String, dynamic>), m);
  }

  final ResultadoMotor resultado;

  /// Tamano del cuadro (orientacion del sensor) y bytes por fila.
  final int ancho, alto, fila;

  /// Grados a girar el cuadro para verlo en vertical.
  final int giro;

  /// Contadores desde que se encendio: cuadros analizados y entregados por el sensor.
  final int analizados, sensor;

  /// Tiempo de la llamada al motor (en Java), y edad del cuadro al terminar
  /// (desde que lo tomo el sensor; -1 si no se sabe).
  final int msMotor, edadMs;

  /// Velocidad de giro del telefono (rad/s, giroscopio).
  final double velocidadGiro;

  /// Exposicion e ISO con que el sensor tomo los ultimos cuadros.
  final int exposicionNs, iso;

  /// "propia" (1/250 s), "probando_propia", "auto_corta(ev=..)" o "auto".
  final String modoExposicion;
}

/// Convierte el JSON del motor (jni_camara.cpp) al mismo resultado que [leerCuadro].
ResultadoMotor resultadoDesdeJson(Map<String, dynamic> m) {
  final i = m['i'] as Map<String, dynamic>;
  final tp = (i['tp'] as List).cast<int>();
  return ResultadoMotor(
    [
      for (final c in (m['c'] as List).cast<Map<String, dynamic>>())
        CodigoMotor(
          texto: c['t'] as String,
          formato: c['f'] as String,
          bitFormato: c['b'] as int,
          paso: PasoMotor.values[(c['p'] as int).clamp(0, PasoMotor.values.length - 1)],
          invertido: c['i'] == 1,
          sinLeer: c['s'] == 1,
          verificado: c['v'] == 1,
          rechazado: c['v'] == -1,
          esquinas: [
            for (var k = 0; k < 4; k++)
              ((c['x'] as List)[k].toDouble() as double, (c['y'] as List)[k].toDouble() as double),
          ],
        ),
    ],
    InfoMotor(
      brillo: i['brillo'] as int,
      contraste: i['contraste'] as int,
      quemados: i['quemados'] as int,
      sugerirLinterna: i['linterna'] == 1,
      pasos: i['pasos'] as int,
      siguienteRonda: i['ronda'] as int,
      microsegundos: i['us'] as int,
      nitidez: i['nitidez'] as int,
      ilegibles: i['ilegibles'] as int,
      hilos: i['hilos'] as int,
      regiones: i['regiones'] as int,
      tiempoPorPaso: {
        for (var p = 1; p < tp.length && p < PasoMotor.values.length; p++)
          if (tp[p] > 0) PasoMotor.values[p]: tp[p],
      },
    ),
  );
}

/// Canales con el plugin Java (CamaraNativaPlugin).
abstract final class CamaraNativa {
  static const _canal = MethodChannel('difar/camara');
  static const _eventos = EventChannel('difar/camara/resultados');

  static Stream<CuadroNativo> cuadros() =>
      _eventos.receiveBroadcastStream().map((e) => CuadroNativo.desdeJson(e as String));

  /// Pide el permiso si falta (error 'permiso' si se niega) y enciende.
  static Future<DatosCamara> iniciar({
    required bool alta,
    required int formatos,
    required int modo,
    int presupuestoUs = 0,
    bool exposicionPropia = true,
  }) async {
    final m = await _canal.invokeMapMethod<Object?, Object?>('iniciar', {
      'alta': alta,
      'formatos': formatos,
      'modo': modo,
      'presupuestoUs': presupuestoUs,
      'exposicionPropia': exposicionPropia,
    });
    return DatosCamara(m!);
  }

  static Future<void> detener() => _canal.invokeMethod('detener');

  static Future<void> configurar({int? formatos, int? modo, int? presupuestoUs, bool? exposicionPropia}) =>
      _canal.invokeMethod('configurar', {
        'formatos': ?formatos,
        'modo': ?modo,
        'presupuestoUs': ?presupuestoUs,
        'exposicionPropia': ?exposicionPropia,
      });

  static Future<void> linterna(bool encendida) => _canal.invokeMethod('linterna', {'encendida': encendida});

  static Future<void> zoom(double aumento) => _canal.invokeMethod('zoom', {'aumento': aumento});

  /// [x], [y] normalizados (0..1) en el cuadro, orientacion del sensor.
  static Future<void> enfocar(double x, double y) => _canal.invokeMethod('enfocar', {'x': x, 'y': y});

  /// Vuelve al enfoque continuo.
  static Future<void> reenfocar() => _canal.invokeMethod('reenfocar');

  static Future<void> pausar(bool pausada) => _canal.invokeMethod('pausar', {'pausada': pausada});

  /// Cuadros de diagnostico guardados (JPEG en gris + JSON con lo que leyo el motor).
  static Future<List<String>> archivosDiagnostico() async =>
      (await _canal.invokeListMethod<String>('diagnostico')) ?? const [];

  static Future<void> borrarDiagnostico() => _canal.invokeMethod('borrarDiagnostico');
}
