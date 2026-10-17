/// Motor de lectura de codigos de barras en C++ (src/motor_lector.cpp) por FFI.
///
/// [MotorLector] corre el motor en un isolate propio: la interfaz nunca se
/// traba aunque un cuadro dificil tarde. [leerCuadro] es la llamada directa
/// (sincrona), para el isolate y para las pruebas.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ------------------------------------------------------------------ constantes

/// Formato de los pixeles de entrada (ML_PIXEL_* en motor_lector.h).
enum FormatoPixel { luma, bgra }

/// Bits de formato (ML_* en motor_lector.h). 0 = todos.
abstract final class FormatosMotor {
  static const ean13 = 1 << 0;
  static const ean8 = 1 << 1;
  static const upcA = 1 << 2;
  static const upcE = 1 << 3;
  static const code128 = 1 << 4;
  static const code39 = 1 << 5;
  static const code93 = 1 << 6;
  static const itf = 1 << 7;
  static const codabar = 1 << 8;
  static const dataBar = 1 << 9;
  static const qr = 1 << 10;
  static const dataMatrix = 1 << 11;
  static const pdf417 = 1 << 12;
  static const aztec = 1 << 13;
  static const microQr = 1 << 14;
}

/// Modo de lectura (ML_MODO_* en motor_lector.h), se combinan con |.
abstract final class ModoMotor {
  /// Todos los codigos del cuadro (si no, corta con el primero).
  static const todos = 1;

  /// Todo el cuadro (si no, la zona central).
  static const cuadroCompleto = 2;

  /// Solo el paso rapido (camara sin disparar: ahorra bateria).
  static const soloRapido = 4;
}

/// Paso del motor que logro la lectura (ML_PASO_*).
enum PasoMotor {
  ninguno('-'),
  rapido('rapido'),
  completo('completo'),
  pocaLuz('poca luz'),
  reflejos('reflejos/sombras'),
  ampliado('ampliado'),
  invertido('invertido'),
  rotado('rotado');

  const PasoMotor(this.nombre);
  final String nombre;
}

// ------------------------------------------------------------------ resultados

class CodigoMotor {
  const CodigoMotor({
    required this.texto,
    required this.formato,
    required this.bitFormato,
    required this.paso,
    required this.invertido,
    required this.esquinas,
  });

  final String texto;

  /// Nombre del formato segun zxing ("EAN-13", "Code 128", "QR Code"...).
  final String formato;
  final int bitFormato;
  final PasoMotor paso;
  final bool invertido;

  /// 4 esquinas (x, y) en pixeles de la imagen de entrada.
  final List<(double, double)> esquinas;
}

class InfoMotor {
  const InfoMotor({
    this.brillo = 0,
    this.contraste = 0,
    this.quemados = 0,
    this.sugerirLinterna = false,
    this.pasos = 0,
    this.siguienteRonda = 0,
    this.microsegundos = 0,
    this.tiempoPorPaso = const {},
    this.nitidez = 0,
    this.ilegibles = 0,
    this.hilos = 0,
  });

  /// 0..255, promedio del centro del cuadro.
  final int brillo;
  final int contraste;

  /// % de pixeles casi blancos (reflejos).
  final int quemados;
  final bool sugerirLinterna;
  final int pasos;

  /// Pasar en [ronda] del proximo cuadro: los pasos dificiles siguen donde quedaron.
  final int siguienteRonda;
  final int microsegundos;
  final Map<PasoMotor, int> tiempoPorPaso;

  /// Promedio del |laplaciano| del centro: bajo = desenfocado o movido.
  final int nitidez;

  /// Simbolos encontrados que fallaron la verificacion (codigo danado).
  final int ilegibles;

  /// Hilos usados en los pasos dificiles (1 = uno tras otro).
  final int hilos;
}

class ResultadoMotor {
  const ResultadoMotor(this.codigos, this.info);

  final List<CodigoMotor> codigos;
  final InfoMotor info;
}

// ------------------------------------------------------------------ FFI

const _maxSalida = 64;
const _pasos = 8; // ML_PASOS

final class _MlCodigo extends Struct {
  @Int32()
  external int formato;
  @Int32()
  external int paso;
  @Int32()
  external int invertido;
  @Array(4)
  external Array<Int32> x;
  @Array(4)
  external Array<Int32> y;
  @Array(32)
  external Array<Uint8> nombreFormato;
  @Array(1024)
  external Array<Uint8> texto;
}

final class _MlInfo extends Struct {
  @Int32()
  external int brillo;
  @Int32()
  external int contraste;
  @Int32()
  external int quemados;
  @Int32()
  external int sugerirLinterna;
  @Int32()
  external int pasos;
  @Int32()
  external int siguienteRonda;
  @Int32()
  external int microsegundos;
  @Array(_pasos)
  external Array<Int32> tiempoPasoUs;
  @Int32()
  external int nitidez;
  @Int32()
  external int ilegibles;
  @Int32()
  external int hilos;
}

typedef _LeerC = Int32 Function(Pointer<Uint8>, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
    Pointer<_MlCodigo>, Int32, Pointer<_MlInfo>);
typedef _ConfigurarC = Void Function(Int32);
typedef _ConfigurarDart = void Function(int);

typedef _LeerDart = int Function(
    Pointer<Uint8>, int, int, int, int, int, int, int, int, Pointer<_MlCodigo>, int, Pointer<_MlInfo>);

DynamicLibrary _abrir() {
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libmotor_lector.so');
  throw UnsupportedError('Motor de lectura no disponible en ${Platform.operatingSystem}');
}

/// Abre la biblioteca de [ruta] (pruebas en la PC) o la de la app.
_LeerDart _funcion([String? ruta]) {
  final lib = ruta == null ? _abrir() : DynamicLibrary.open(ruta);
  return lib.lookupFunction<_LeerC, _LeerDart>('ml_leer');
}

String _cadena(Array<Uint8> a, int largo) {
  final bytes = <int>[];
  for (var i = 0; i < largo && a[i] != 0; i++) {
    bytes.add(a[i]);
  }
  return const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// Hilos para los pasos dificiles: 0 = segun los nucleos (en paralelo, por
/// defecto), 1 = uno tras otro. Afecta a todo el proceso (todos los isolates).
void configurarHilos(int hilos, {String? biblioteca}) {
  final lib = biblioteca == null ? _abrir() : DynamicLibrary.open(biblioteca);
  lib.lookupFunction<_ConfigurarC, _ConfigurarDart>('ml_configurar')(hilos);
}

/// Memoria nativa reutilizada entre cuadros (una por isolate).
class _Memoria {
  _Memoria(this.leer);

  final _LeerDart leer;
  Pointer<Uint8> _pixeles = nullptr;
  int _capacidad = 0;
  final Pointer<_MlCodigo> salida = calloc<_MlCodigo>(_maxSalida);
  final Pointer<_MlInfo> info = calloc<_MlInfo>();

  Pointer<Uint8> pixeles(int largo) {
    if (largo > _capacidad) {
      if (_pixeles != nullptr) calloc.free(_pixeles);
      _pixeles = calloc<Uint8>(largo);
      _capacidad = largo;
    }
    return _pixeles;
  }
}

_Memoria? _memoria;

/// Lee un cuadro de forma sincrona. [pixeles]: plano de luminancia (o BGRA)
/// con [bytesPorFila] por fila; puede traer datos de mas al final (NV21).
ResultadoMotor leerCuadro(
  Uint8List pixeles, {
  required int ancho,
  required int alto,
  required int bytesPorFila,
  FormatoPixel formatoPixel = FormatoPixel.luma,
  int formatos = 0,
  int modo = 0,
  int presupuestoUs = 0,
  int ronda = 0,
  String? biblioteca,
}) {
  final m = _memoria ??= _Memoria(_funcion(biblioteca));
  final largo = bytesPorFila * alto;
  if (pixeles.length < largo) {
    throw ArgumentError('Faltan pixeles: ${pixeles.length} < $largo');
  }
  final destino = m.pixeles(largo);
  destino.asTypedList(largo).setRange(0, largo, pixeles);

  final n = m.leer(destino, ancho, alto, bytesPorFila, formatoPixel.index, formatos, modo,
      presupuestoUs, ronda, m.salida, _maxSalida, m.info);

  final codigos = <CodigoMotor>[
    for (var i = 0; i < n; i++)
      () {
        final c = (m.salida + i).ref;
        return CodigoMotor(
          texto: _cadena(c.texto, 1024),
          formato: _cadena(c.nombreFormato, 32),
          bitFormato: c.formato,
          paso: PasoMotor.values[c.paso.clamp(0, PasoMotor.values.length - 1)],
          invertido: c.invertido != 0,
          esquinas: [for (var k = 0; k < 4; k++) (c.x[k].toDouble(), c.y[k].toDouble())],
        );
      }(),
  ];
  final i = m.info.ref;
  return ResultadoMotor(
    codigos,
    InfoMotor(
      brillo: i.brillo,
      contraste: i.contraste,
      quemados: i.quemados,
      sugerirLinterna: i.sugerirLinterna != 0,
      pasos: i.pasos,
      siguienteRonda: i.siguienteRonda,
      microsegundos: i.microsegundos,
      nitidez: i.nitidez,
      ilegibles: i.ilegibles,
      hilos: i.hilos,
      tiempoPorPaso: {
        for (var p = 1; p < _pasos && p < PasoMotor.values.length; p++)
          if (i.tiempoPasoUs[p] > 0) PasoMotor.values[p]: i.tiempoPasoUs[p],
      },
    ),
  );
}

// ------------------------------------------------------------------ isolate

class _Pedido {
  _Pedido(this.id, this.pixeles, this.ancho, this.alto, this.bytesPorFila, this.formatoPixel, this.formatos,
      this.modo, this.presupuestoUs, this.ronda);

  final int id;
  final TransferableTypedData pixeles;
  final int ancho, alto, bytesPorFila;
  final FormatoPixel formatoPixel;
  final int formatos;
  final int modo;
  final int presupuestoUs;
  final int ronda;
}

/// Motor en un isolate propio. Un pedido a la vez: si llega un cuadro
/// mientras se procesa otro, conviene descartarlo (ver [ocupado]).
class MotorLector {
  MotorLector._(this._isolate, this._envio, this._respuestas);

  final Isolate _isolate;
  final SendPort _envio;
  final ReceivePort _respuestas;
  final _pendientes = <int, Completer<ResultadoMotor>>{};
  int _ultimoId = 0;

  bool get ocupado => _pendientes.isNotEmpty;

  static Future<MotorLector> iniciar() async {
    final respuestas = ReceivePort();
    final isolate = await Isolate.spawn(_trabajador, respuestas.sendPort, debugName: 'motor_lector');
    final primero = Completer<SendPort>();
    late final MotorLector motor;
    respuestas.listen((mensaje) {
      if (mensaje is SendPort) {
        primero.complete(mensaje);
      } else if (mensaje is (int, ResultadoMotor)) {
        motor._pendientes.remove(mensaje.$1)?.complete(mensaje.$2);
      } else if (mensaje is (int, String)) {
        motor._pendientes.remove(mensaje.$1)?.completeError(StateError(mensaje.$2));
      }
    });
    motor = MotorLector._(isolate, await primero.future, respuestas);
    return motor;
  }

  Future<ResultadoMotor> leer(
    Uint8List pixeles, {
    required int ancho,
    required int alto,
    required int bytesPorFila,
    FormatoPixel formatoPixel = FormatoPixel.luma,
    int formatos = 0,
    int modo = 0,
    int presupuestoUs = 0,
    int ronda = 0,
  }) {
    final id = ++_ultimoId;
    final c = _pendientes[id] = Completer<ResultadoMotor>();
    // Solo se manda el plano que usa el motor (sin el color de NV21).
    final largo = bytesPorFila * alto;
    final vista = pixeles.length > largo ? Uint8List.sublistView(pixeles, 0, largo) : pixeles;
    _envio.send(_Pedido(id, TransferableTypedData.fromList([vista]), ancho, alto, bytesPorFila, formatoPixel,
        formatos, modo, presupuestoUs, ronda));
    return c.future;
  }

  void cerrar() {
    for (final c in _pendientes.values) {
      c.completeError(StateError('Motor cerrado'));
    }
    _pendientes.clear();
    _respuestas.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _trabajador(SendPort respuestas) {
    final pedidos = ReceivePort();
    respuestas.send(pedidos.sendPort);
    pedidos.listen((mensaje) {
      final p = mensaje as _Pedido;
      try {
        final r = leerCuadro(
          p.pixeles.materialize().asUint8List(),
          ancho: p.ancho,
          alto: p.alto,
          bytesPorFila: p.bytesPorFila,
          formatoPixel: p.formatoPixel,
          formatos: p.formatos,
          modo: p.modo,
          presupuestoUs: p.presupuestoUs,
          ronda: p.ronda,
        );
        respuestas.send((p.id, r));
      } catch (e) {
        respuestas.send((p.id, '$e'));
      }
    });
  }
}
