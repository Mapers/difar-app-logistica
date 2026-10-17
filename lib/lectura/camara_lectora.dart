import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart' as mlkit;
import 'package:motor_lector/motor_lector.dart';

import '../core/codigos.dart';
import '../core/registro.dart';
import 'ajustes.dart';
import 'fusion.dart';

/// Lo que se vio en un cuadro.
class Captura {
  Captura(this.imagen, this.codigos, {this.info, this.ilegible = false});

  /// Tamano de la imagen en vertical (las esquinas estan en este espacio).
  final Size imagen;
  final List<CodigoVisto> codigos;

  /// Medicion del motor C++ (luz, reflejos, tiempos). Null si no corrio.
  final InfoMotor? info;

  /// ML Kit vio un codigo pero no pudo sacar su contenido.
  final bool ilegible;
}

/// Camara + los dos motores de lectura sobre el mismo cuadro:
/// * motor C++ (zxing-cpp + preparacion: oscuridad, reflejos, invertidos,
///   rotados), en su propio isolate;
/// * Google ML Kit (muy bueno con codigos curvos o desenfocados).
/// Se procesa un cuadro a la vez; los que llegan mientras tanto se descartan,
/// asi la vista previa nunca se atrasa.
class CamaraLectora extends ChangeNotifier with WidgetsBindingObserver {
  CamaraLectora(this.ajustes, {this.multiple = false});

  final Ajustes ajustes;

  /// Conteo multiple: busca todos los codigos del cuadro, no solo el centro.
  final bool multiple;

  /// Tope de tiempo del motor C++ por cuadro (los pasos dificiles siguen en
  /// los cuadros siguientes).
  static const presupuestoUs = 45000;

  CameraController? _control;
  CameraController? get control => _control;
  MotorLector? _motor;
  mlkit.BarcodeScanner? _mlkit;
  GrupoFormatos? _grupoMlkit;
  final _fusion = Fusion();
  final _capturas = StreamController<Captura>.broadcast();
  Stream<Captura> get capturas => _capturas.stream;

  bool _procesando = false;
  bool _observando = false;
  bool _encendida = false;
  bool _cerrada = false;
  int _ronda = 0;

  String? error;
  bool permisoDenegado = false;
  bool linterna = false;
  /// Aumento actual (1 = sin zoom).
  double aumento = 1;
  double _zoomMin = 1, _zoomMax = 1;
  int _cuadrosOscuros = 0;

  /// Se encendio la linterna sola por poca luz (para avisar una vez).
  bool linternaAutomatica = false;

  /// Medicion del ultimo cuadro (para el registro de fallos).
  InfoMotor? ultimaInfo;

  // Estadisticas para el registro (se vuelcan cada 2 s).
  final _reloj = Stopwatch();
  int _recibidos = 0, _procesados = 0, _cuadrosConCodigo = 0;
  int _msCppTotal = 0, _msCppMax = 0, _msMlTotal = 0, _msMlMax = 0;
  bool _tamanoRegistrado = false;

  bool get lista => _control?.value.isInitialized ?? false;
  bool get encendida => _encendida;

  /// Encender y apagar van en fila: el permiso de camara (y salir y volver a
  /// la app) pide apagar mientras todavia se esta encendiendo, y sin fila
  /// quedaban dos camaras abiertas.
  Future<void> _cola = Future.value();

  Future<void> _enFila(Future<void> Function() accion) {
    final siguiente = _cola.then((_) => accion());
    _cola = siguiente.catchError((Object _) {});
    return siguiente;
  }

  Future<void> iniciar() => _enFila(_iniciar);

  Future<void> _iniciar() async {
    if (_cerrada || _encendida) return;
    _encendida = true;
    if (!_observando) {
      // Para apagar la camara en segundo plano y volver a encenderla.
      WidgetsBinding.instance.addObserver(this);
      _observando = true;
    }
    try {
      final camaras = await availableCameras();
      final trasera = camaras.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => camaras.first);
      final control = CameraController(
        trasera,
        multiple || ajustes.altaResolucion ? ResolutionPreset.veryHigh : ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await control.initialize();
      if (_cerrada || !_encendida) {
        await control.dispose();
        return;
      }
      _control = control;
      try {
        await control.setFocusMode(FocusMode.auto);
      } catch (_) {}
      _zoomMin = await control.getMinZoomLevel();
      _zoomMax = math.min(await control.getMaxZoomLevel(), 8);
      if (aumento != 1) await control.setZoomLevel(aumento.clamp(_zoomMin, _zoomMax));
      if (linterna) await control.setFlashMode(FlashMode.torch);
      await _prepararMotores();
      await control.startImageStream(_alCuadro);
      error = null;
      permisoDenegado = false;
      _tamanoRegistrado = false;
      _reloj
        ..reset()
        ..start();
      registrar('CAMARA', 'encendida ${multiple ? "multiple" : "uno"} giro=${trasera.sensorOrientation} '
          'vista=${_tam(control.value.previewSize)} zoom=${_zoomMin.toStringAsFixed(1)}-${_zoomMax.toStringAsFixed(1)} '
          'motor=${ajustes.motor.name} formatos=${ajustes.grupo.name}');
    } on CameraException catch (e) {
      permisoDenegado = e.code.contains('AccessDenied') || e.code.contains('Permission');
      error = permisoDenegado ? null : '${e.code}: ${e.description ?? ''}';
      _encendida = false;
      registrar('ERROR', 'camara ${e.code}: ${e.description}');
    } catch (e) {
      error = '$e';
      _encendida = false;
      registrar('ERROR', 'camara $e');
    }
    notifyListeners();
  }

  Future<void> _prepararMotores() async {
    final motor = ajustes.motor;
    if (motor != MotorLectura.mlkit) _motor ??= await MotorLector.iniciar();
    if (motor != MotorLectura.cpp && (_mlkit == null || _grupoMlkit != ajustes.grupo)) {
      await _mlkit?.close();
      _grupoMlkit = ajustes.grupo;
      _mlkit = mlkit.BarcodeScanner(formats: ajustes.grupo.formatosMlkit);
    }
  }

  /// Apaga la camara (libera el sensor para otra pantalla o ahorra bateria).
  Future<void> apagar() => _enFila(_apagar);

  Future<void> _apagar() async {
    if (_encendida) {
      _volcarEstadisticas();
      registrar('CAMARA', 'apagada');
    }
    _encendida = false;
    final control = _control;
    _control = null;
    notifyListeners();
    if (control != null) {
      try {
        if (control.value.isStreamingImages) await control.stopImageStream();
      } catch (_) {}
      await control.dispose();
    }
  }

  static String _tam(Size? s) => s == null ? '?' : '${s.width.toInt()}x${s.height.toInt()}';

  Future<void> cambiarLinterna([bool? encender]) async {
    linterna = encender ?? !linterna;
    linternaAutomatica = false;
    registrar('CAMARA', 'linterna ${linterna ? "encendida" : "apagada"}');
    notifyListeners();
    try {
      await _control?.setFlashMode(linterna ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
  }

  Future<void> fijarAumento(double x) async {
    aumento = x.clamp(_zoomMin, math.max(_zoomMin, _zoomMax));
    notifyListeners();
    try {
      await _control?.setZoomLevel(aumento);
    } catch (_) {}
  }

  /// [punto] normalizado (0..1) sobre la vista previa.
  Future<void> enfocar(Offset punto) async {
    try {
      await _control?.setFocusPoint(punto);
      await _control?.setExposurePoint(punto);
    } catch (_) {}
  }

  // ------------------------------------------------------------ cuadros

  void _alCuadro(CameraImage img) {
    _recibidos++;
    if (_procesando || !_encendida) return;
    _procesando = true;
    _procesar(img).catchError((Object e) => debugPrint('Lector: $e')).whenComplete(() => _procesando = false);
  }

  Future<void> _procesar(CameraImage img) async {
    final control = _control;
    if (control == null) return;
    final giro = control.description.sensorOrientation;
    final plano = img.planes.first;
    final sensor = Size(img.width.toDouble(), img.height.toDouble());
    final grupo = ajustes.grupo;

    // Los dos motores a la vez sobre el mismo cuadro.
    final cpp = _motor?.leer(
      plano.bytes,
      ancho: img.width,
      alto: img.height,
      bytesPorFila: plano.bytesPerRow,
      formatoPixel: Platform.isAndroid ? FormatoPixel.luma : FormatoPixel.bgra,
      formatos: grupo.mascaraMotor,
      multiple: multiple,
      presupuestoUs: presupuestoUs,
      ronda: _ronda,
    );
    final ml = _mlkit?.processImage(mlkit.InputImage.fromBytes(
      bytes: plano.bytes,
      metadata: mlkit.InputImageMetadata(
        size: sensor,
        rotation: mlkit.InputImageRotationValue.fromRawValue(giro) ?? mlkit.InputImageRotation.rotation0deg,
        format: Platform.isAndroid ? mlkit.InputImageFormat.nv21 : mlkit.InputImageFormat.bgra8888,
        bytesPerRow: plano.bytesPerRow,
      ),
    ));

    final t0 = DateTime.now();
    int? msCpp, msMl;
    final esperaCpp = cpp?.then((v) {
      msCpp = DateTime.now().difference(t0).inMilliseconds;
      return v;
    });
    final esperaMl = ml?.then((v) {
      msMl = DateTime.now().difference(t0).inMilliseconds;
      return v;
    });
    ResultadoMotor? r;
    List<mlkit.Barcode> lm = const [];
    try {
      r = await esperaCpp;
    } catch (e) {
      registrar('ERROR', 'motor C++: $e');
    }
    try {
      lm = await esperaMl ?? const [];
    } catch (e) {
      registrar('ERROR', 'ML Kit: $e');
    }
    if (r != null) _ronda = r.info.siguienteRonda;
    ultimaInfo = r?.info ?? ultimaInfo;
    if (!_tamanoRegistrado) {
      _tamanoRegistrado = true;
      registrar('CAMARA', 'cuadro ${img.width}x${img.height} fila=${plano.bytesPerRow} '
          'planos=${img.planes.length} bytes=${plano.bytes.length}');
    }
    _procesados++;
    if (msCpp != null) {
      _msCppTotal += msCpp!;
      if (msCpp! > _msCppMax) _msCppMax = msCpp!;
    }
    if (msMl != null) {
      _msMlTotal += msMl!;
      if (msMl! > _msMlMax) _msMlMax = msMl!;
    }
    if ((r?.codigos.isNotEmpty ?? false) || lm.isNotEmpty) _cuadrosConCodigo++;
    if (_reloj.elapsedMilliseconds >= 2000) _volcarEstadisticas();

    final deCpp = [
      for (final c in r?.codigos ?? const <CodigoMotor>[])
        CodigoVisto(
          c.texto,
          Simbologia.deMotor(c.bitFormato)?.nombre ?? c.formato,
          [for (final p in c.esquinas) aVertical(Offset(p.$1, p.$2), sensor, giro)],
          simbologia: Simbologia.deMotor(c.bitFormato),
          fuente: 'C++',
          detalle: c.paso.nombre,
        ),
    ];
    // ML Kit ya devuelve las esquinas en la imagen girada.
    final deMlkit = [
      for (final b in lm)
        if (b.rawValue != null && b.rawValue!.isNotEmpty)
          CodigoVisto(
            b.rawValue!,
            Simbologia.deMlkit(b.format)?.nombre ?? b.format.name,
            [for (final p in b.cornerPoints) Offset(p.x.toDouble(), p.y.toDouble())],
            simbologia: Simbologia.deMlkit(b.format),
            fuente: 'ML Kit',
          ),
    ];
    final ilegible = lm.any((b) => b.rawValue == null || b.rawValue!.isEmpty);

    if (r != null) _linternaAutomatica(r.info);
    if (!_capturas.isClosed && _encendida) {
      _capturas.add(Captura(tamVertical(sensor, giro), _fusion.fusionar(deCpp, deMlkit),
          info: r?.info, ilegible: ilegible));
    }
  }

  void _volcarEstadisticas() {
    final seg = _reloj.elapsedMilliseconds / 1000;
    if (_procesados > 0 && seg > 0) {
      final i = ultimaInfo;
      registrar('CUADROS', 'en ${seg.toStringAsFixed(1)}s: recibidos=$_recibidos procesados=$_procesados '
          '(${(_procesados / seg).toStringAsFixed(1)}/s) con_codigo=$_cuadrosConCodigo '
          'C++ prom=${_msCppTotal ~/ _procesados}ms max=${_msCppMax}ms '
          'MLKit prom=${_msMlTotal ~/ _procesados}ms max=${_msMlMax}ms'
          '${i == null ? '' : ' brillo=${i.brillo} contraste=${i.contraste} nitidez=${i.nitidez} reflejo=${i.quemados}%'} '
          'linterna=${linterna ? "si" : "no"} zoom=${aumento.toStringAsFixed(1)}');
    }
    _recibidos = _procesados = _cuadrosConCodigo = 0;
    _msCppTotal = _msCppMax = _msMlTotal = _msMlMax = 0;
    _reloj
      ..reset()
      ..start();
  }

  /// Con poca luz sostenida (~1 s) enciende la linterna sola, si esta activado.
  void _linternaAutomatica(InfoMotor info) {
    if (!ajustes.linternaAuto || linterna) return;
    _cuadrosOscuros = info.sugerirLinterna ? _cuadrosOscuros + 1 : 0;
    if (_cuadrosOscuros >= 12) {
      _cuadrosOscuros = 0;
      registrar('CAMARA', 'poca luz (brillo ${info.brillo}): linterna automatica');
      unawaited(cambiarLinterna(true).then((_) {
        linternaAutomatica = true;
        notifyListeners();
      }));
    }
  }

  // ------------------------------------------------------------ ciclo de vida

  bool _apagadaPorSegundoPlano = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_encendida) {
        _apagadaPorSegundoPlano = true;
        unawaited(apagar());
      }
    } else if (state == AppLifecycleState.resumed && _apagadaPorSegundoPlano) {
      _apagadaPorSegundoPlano = false;
      unawaited(iniciar());
    }
  }

  @override
  void dispose() {
    _cerrada = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(apagar().whenComplete(() => _motor?.cerrar()));
    unawaited(_mlkit?.close());
    unawaited(_capturas.close());
    super.dispose();
  }
}

/// Vista previa de [camara] cubriendo todo su espacio (como `BoxFit.cover`).
/// Tocar = enfocar ahi.
class VistaCamara extends StatelessWidget {
  const VistaCamara({super.key, required this.camara, this.alTocar});

  final CamaraLectora camara;
  final VoidCallback? alTocar;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: camara,
      builder: (context, _) {
        final control = camara.control;
        if (camara.permisoDenegado) {
          return const _Aviso('Sin permiso de camara. Activalo en Ajustes del telefono > Apps > DIFAR Logistica.');
        }
        if (camara.error != null) return _Aviso('No se pudo abrir la camara (${camara.error}).');
        if (control == null || !control.value.isInitialized) return const ColoredBox(color: Colors.black);
        final previa = control.value.previewSize!;
        return LayoutBuilder(
          builder: (context, c) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              alTocar?.call();
              camara.enfocar(Offset(d.localPosition.dx / c.maxWidth, d.localPosition.dy / c.maxHeight));
            },
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  // previewSize viene en horizontal; la app esta en vertical.
                  width: previa.height,
                  height: previa.width,
                  child: CameraPreview(control),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      );
}
