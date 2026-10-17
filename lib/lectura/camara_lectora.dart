import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:motor_lector/camara_nativa.dart';
import 'package:motor_lector/motor_lector.dart';

import '../core/codigos.dart';
import '../core/registro.dart';
import 'ajustes.dart';
import 'fusion.dart';

/// Lo que se vio en un cuadro.
class Captura {
  Captura(this.imagen, this.codigos,
      {this.info, this.ilegible = false, this.sinLeer = const [], this.crudos = const []});

  /// Tamano de la imagen en vertical (las esquinas estan en este espacio).
  final Size imagen;
  final List<CodigoVisto> codigos;

  /// Medicion del motor (luz, reflejos, tiempos). Null si no corrio.
  final InfoMotor? info;

  /// El motor encontro un codigo pero fallo su verificacion (danado).
  final bool ilegible;

  /// Zonas (4 esquinas, en vertical) donde OpenCV ve un codigo que no se
  /// pudo leer: marca "acercate".
  final List<List<Offset>> sinLeer;

  /// Todo lo leido en el cuadro, antes de la confirmacion de [Fusion] (el
  /// conteo vota por su cuenta, caja por caja).
  final List<CodigoVisto> crudos;
}

/// Camara nativa (CameraX) + motor de lectura propio (C++: zxing-cpp,
/// OpenCV y preparacion de imagen), como los SDK comerciales: cada cuadro va
/// del sensor al motor dentro de Android, sin copiar pixeles a Dart; aca solo
/// llegan los codigos. Si el motor esta ocupado la camara descarta cuadros
/// (se procesa siempre el ultimo), asi nunca se atrasa.
class CamaraLectora extends ChangeNotifier with WidgetsBindingObserver {
  CamaraLectora(this.ajustes, {this.multiple = false});

  final Ajustes ajustes;

  /// Conteo multiple: busca todos los codigos del cuadro, no solo el centro.
  final bool multiple;

  /// Mientras sea true busca todos los codigos del cuadro aunque la camara
  /// sea de "uno" (al mantener presionado el boton se leen todos a la vez).
  bool get buscarTodos => _buscarTodos;
  set buscarTodos(bool v) {
    if (v == _buscarTodos) return;
    _buscarTodos = v;
    _configurar();
  }

  bool _buscarTodos = false;

  /// Con el boton presionado (o en conteo multiple): todos los pasos del
  /// motor. Sin disparar solo el rapido, para mostrar los recuadros sin
  /// gastar procesador ni bateria.
  bool get esfuerzo => _esfuerzo;
  set esfuerzo(bool v) {
    if (v == _esfuerzo) return;
    _esfuerzo = v;
    _configurar();
  }

  bool _esfuerzo = false;

  /// Tope de tiempo por cuadro, solo si el motor corre uno tras otro (en
  /// paralelo prueba todo en cada cuadro).
  static const presupuestoUs = 45000;

  int get _modo =>
      (multiple ? ModoMotor.todos | ModoMotor.cuadroCompleto : 0) |
      (_buscarTodos ? ModoMotor.todos : 0) |
      (_esfuerzo ? ModoMotor.intercalar : ModoMotor.soloRapido);

  void _configurar() {
    if (!_encendida) return;
    unawaited(CamaraNativa.configurar(modo: _modo, formatos: ajustes.grupo.mascaraMotor,
        exposicionPropia: ajustes.exposicionPropia).catchError((Object _) {}));
  }

  DatosCamara? _datos;

  /// Datos de la camara encendida (textura de la vista previa).
  DatosCamara? get datos => _datos;
  StreamSubscription<CuadroNativo>? _suscripcion;
  final _fusion = Fusion();
  final _capturas = StreamController<Captura>.broadcast();
  Stream<Captura> get capturas => _capturas.stream;

  bool _observando = false;
  bool _encendida = false;
  bool _cerrada = false;

  String? error;
  bool permisoDenegado = false;
  bool linterna = false;
  /// Aumento actual (1 = sin zoom).
  double aumento = 1;
  int _cuadrosOscuros = 0;

  /// Se encendio la linterna sola por poca luz (para avisar una vez).
  bool linternaAutomatica = false;

  /// Medicion del ultimo cuadro (para el registro de fallos).
  InfoMotor? ultimaInfo;

  /// Tamano del ultimo cuadro analizado (orientacion del sensor) y su giro.
  Size _sensor = Size.zero;
  int _giro = 90;

  /// Desde cuando hay un codigo a la vista (leido, retenido o ubicado por
  /// OpenCV) sin interrupcion, para medir cuanto tarda una lectura desde que
  /// el codigo aparece (y no desde la lectura anterior).
  DateTime? _primerVisto;
  int _cuadrosSinCodigo = 0;

  /// Milisegundos desde que aparecio un codigo a la vista (null si no hay).
  int? get msVisible => _primerVisto == null ? null : DateTime.now().difference(_primerVisto!).inMilliseconds;

  /// Tras contar una lectura, la medicion empieza de nuevo para el siguiente.
  void reiniciarVisible() => _primerVisto = null;

  // Estadisticas para el registro (se vuelcan cada 2 s).
  final _reloj = Stopwatch();
  int _sensorInicio = -1, _analizadosInicio = 0, _ultimoSensor = 0, _ultimoAnalizado = 0;
  int _procesados = 0, _cuadrosConCodigo = 0;
  int _msMotorTotal = 0, _msMotorMax = 0, _edadTotal = 0, _edadMax = 0, _conEdad = 0, _leidosEnLapso = 0;
  int _usRapido = 0, _usDetector = 0, _usDificiles = 0, _conDificiles = 0;
  // Dentro del detector: lector en tonos de gris y redes propias (EAN y restauracion).
  static const _pasosRedes = {PasoMotor.gris, PasoMotor.red, PasoMotor.restaurado};
  int _usRedes = 0, _conRedes = 0;
  int _expNs = 0, _iso = 0;
  double _giroTotal = 0, _giroMax = 0;
  int _cuadrosMoviendo = 0;
  String _modoExp = '?';
  bool _tamanoRegistrado = false;

  bool get lista => _datos != null;
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
      _suscripcion ??= CamaraNativa.cuadros().listen(_alCuadro, onError: (Object e) => registrar('ERROR', 'motor: $e'));
      final d = await CamaraNativa.iniciar(
        alta: multiple || ajustes.altaResolucion,
        formatos: ajustes.grupo.mascaraMotor,
        modo: _modo,
        presupuestoUs: presupuestoUs,
        exposicionPropia: ajustes.exposicionPropia,
      );
      if (_cerrada || !_encendida) {
        await CamaraNativa.detener();
        return;
      }
      _datos = d;
      if (aumento != 1) await CamaraNativa.zoom(aumento.clamp(d.zoomMin, math.min(d.zoomMax, 8)));
      if (linterna) await CamaraNativa.linterna(true);
      error = null;
      permisoDenegado = false;
      _tamanoRegistrado = false;
      _sensorInicio = -1;
      _reloj
        ..reset()
        ..start();
      registrar('CAMARA', 'encendida (nativa CameraX) ${multiple ? "multiple" : "uno"} giro=${d.giroSensor} '
          'vista=${d.previaAncho}x${d.previaAlto} giro_vista=${d.giroListo ? "listo" : d.giroVista} '
          'zoom=${d.zoomMin.toStringAsFixed(1)}-${d.zoomMax.toStringAsFixed(1)} '
          'exposicion=${!ajustes.exposicionPropia ? "automatica (ajuste)" : d.exposicionManual ? "propia 1/250s" : "se prueba propia (la camara no la declara)"} '
          'fps=${d.fps} formatos=${ajustes.grupo.name} nucleos=${d.nucleos}');
      registrar('CAMARA', 'sensor ${d.diagnostico}');
    } on PlatformException catch (e) {
      permisoDenegado = e.code == 'permiso';
      error = permisoDenegado ? null : '${e.code}: ${e.message ?? ''}';
      _encendida = false;
      registrar('ERROR', 'camara ${e.code}: ${e.message}');
    } catch (e) {
      error = '$e';
      _encendida = false;
      registrar('ERROR', 'camara $e');
    }
    notifyListeners();
  }

  /// Apaga la camara (libera el sensor para otra pantalla o ahorra bateria).
  Future<void> apagar() => _enFila(_apagar);

  Future<void> _apagar() async {
    if (_encendida) {
      _volcarEstadisticas();
      registrar('CAMARA', 'apagada');
    }
    final habia = _encendida || _datos != null;
    _encendida = false;
    _datos = null;
    notifyListeners();
    if (habia) {
      try {
        await CamaraNativa.detener();
      } catch (_) {}
    }
  }

  static bool _conOpenCV() {
    try {
      return motorConOpenCV();
    } catch (_) {
      return false;
    }
  }

  Future<void> cambiarLinterna([bool? encender]) async {
    linterna = encender ?? !linterna;
    linternaAutomatica = false;
    registrar('CAMARA', 'linterna ${linterna ? "encendida" : "apagada"}');
    notifyListeners();
    if (_datos == null) return;
    try {
      await CamaraNativa.linterna(linterna);
    } catch (_) {}
  }

  /// El operario eligio el aumento con el boton: el automatico no lo toca.
  bool _zoomManual = false;
  bool _zoomAutoActivo = false;
  int _cuadrosChicos = 0;
  DateTime _ultimoCodigo = DateTime.now();

  Future<void> fijarAumento(double x) {
    _zoomManual = x > 1.01;
    _zoomAutoActivo = false;
    return _aplicarAumento(x);
  }

  /// Zoom automatico: si los codigos salen chicos (menos de ~1,8 px por
  /// barra en un EAN) acerca a 2x; vuelve a 1x cuando salen grandes o no
  /// hay codigos a la vista por un rato.
  void _zoomAutomatico(List<CodigoMotor> codigos) {
    if (!ajustes.zoomAuto || _zoomManual || _datos == null || congelada) return;
    final ahora = DateTime.now();
    var mayor = 0.0;
    for (final c in codigos) {
      for (var i = 0; i < 4; i++) {
        final a = c.esquinas[i], b = c.esquinas[(i + 1) % 4];
        final d = math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
        if (d > mayor) mayor = d;
      }
    }
    if (mayor == 0) {
      _cuadrosChicos = 0;
      if (_zoomAutoActivo && ahora.difference(_ultimoCodigo) > const Duration(milliseconds: 2500)) {
        _zoomAutoActivo = false;
        registrar('CAMARA', 'zoom automatico 1x (sin codigos a la vista)');
        unawaited(_aplicarAumento(1));
      }
      return;
    }
    _ultimoCodigo = ahora;
    if (!_zoomAutoActivo && aumento <= 1.01) {
      _cuadrosChicos = mayor < (multiple ? 130 : 170) ? _cuadrosChicos + 1 : 0;
      if (_cuadrosChicos >= 4) {
        _cuadrosChicos = 0;
        _zoomAutoActivo = true;
        registrar('CAMARA', 'zoom automatico 2x (codigo de ${mayor.round()}px)');
        unawaited(_aplicarAumento(2));
      }
    } else if (_zoomAutoActivo && mayor > 640) {
      _zoomAutoActivo = false;
      registrar('CAMARA', 'zoom automatico 1x (codigo de ${mayor.round()}px)');
      unawaited(_aplicarAumento(1));
    }
  }

  Future<void> _aplicarAumento(double x) async {
    final d = _datos;
    aumento = d == null ? x : x.clamp(d.zoomMin, math.max(d.zoomMin, math.min(d.zoomMax, 8)));
    notifyListeners();
    if (d == null) return;
    try {
      await CamaraNativa.zoom(aumento);
    } catch (_) {}
  }

  /// Vuelve al enfoque automatico continuo (cancela un enfoque trabado en un
  /// punto). Para cuando la imagen sigue borrosa mucho rato.
  Future<void> reiniciarEnfoque() async {
    if (_datos == null) return;
    try {
      await CamaraNativa.reenfocar();
    } catch (_) {}
  }

  /// Enfoca en [punto] de la vista ([vista] es su tamano; la imagen se
  /// muestra con `cover`).
  Future<void> enfocar(Offset punto, Size vista) async {
    if (_datos == null || _sensor.isEmpty) return;
    final p = desdeVista(punto, vista);
    try {
      await CamaraNativa.enfocar(p.dx / _sensor.width, p.dy / _sensor.height);
    } catch (_) {}
  }

  /// Lleva un punto de la vista a pixeles del cuadro del sensor.
  Offset desdeVista(Offset punto, Size vista) {
    final vertical = tamVertical(_sensor, _giro);
    final escala = math.max(vista.width / vertical.width, vista.height / vertical.height);
    final v = Offset((punto.dx + (vertical.width * escala - vista.width) / 2) / escala,
        (punto.dy + (vertical.height * escala - vista.height) / 2) / escala);
    return desdeVertical(v, _sensor, _giro);
  }

  // ------------------------------------------------------------ cuadros

  /// Imagen congelada (revision de un disparo de conteo): no se procesa nada.
  bool congelada = false;

  Future<void> congelar() async {
    congelada = true;
    try {
      await CamaraNativa.pausar(true);
    } catch (_) {}
  }

  Future<void> descongelar() async {
    try {
      await CamaraNativa.pausar(false);
    } catch (_) {}
    congelada = false;
  }

  void _alCuadro(CuadroNativo cuadro) {
    if (!_encendida || congelada) return;
    final r = cuadro.resultado;
    final giro = cuadro.giro;
    final sensor = Size(cuadro.ancho.toDouble(), cuadro.alto.toDouble());
    _sensor = sensor;
    _giro = giro;
    ultimaInfo = r.info;
    _expNs = cuadro.exposicionNs;
    _giroTotal += cuadro.velocidadGiro;
    if (cuadro.velocidadGiro > _giroMax) _giroMax = cuadro.velocidadGiro;
    if (cuadro.velocidadGiro > 1.0) _cuadrosMoviendo++;
    _iso = cuadro.iso;
    if (cuadro.modoExposicion != _modoExp) {
      if (_modoExp != '?') registrar('CAMARA', 'exposicion $_modoExp -> ${cuadro.modoExposicion}');
      _modoExp = cuadro.modoExposicion;
    }
    if (_sensorInicio < 0) {
      _sensorInicio = cuadro.sensor;
      _analizadosInicio = cuadro.analizados - 1;
    }
    _ultimoSensor = cuadro.sensor;
    _ultimoAnalizado = cuadro.analizados;
    if (!_tamanoRegistrado) {
      _tamanoRegistrado = true;
      registrar('CAMARA', 'cuadro ${cuadro.ancho}x${cuadro.alto} fila=${cuadro.fila} giro=$giro '
          'hilos_motor=${r.info.hilos} opencv=${_conOpenCV() ? "si" : "no"}');
    }
    _procesados++;
    final msMotor = r.info.microsegundos ~/ 1000;
    _msMotorTotal += msMotor;
    if (msMotor > _msMotorMax) _msMotorMax = msMotor;
    if (cuadro.edadMs >= 0) {
      _edadTotal += cuadro.edadMs;
      _conEdad++;
      if (cuadro.edadMs > _edadMax) _edadMax = cuadro.edadMs;
    }
    if (r.codigos.isNotEmpty) _cuadrosConCodigo++;
    final tp = r.info.tiempoPorPaso;
    _usRapido += tp[PasoMotor.rapido] ?? 0;
    _usDetector += tp[PasoMotor.detector] ?? 0;
    final redes = _pasosRedes.fold(0, (s, p) => s + (tp[p] ?? 0));
    if (redes > 0) {
      _usRedes += redes;
      _conRedes++;
    }
    final dificiles = tp.entries
        .where((e) => e.key != PasoMotor.rapido && e.key != PasoMotor.detector && !_pasosRedes.contains(e.key))
        .fold(0, (s, e) => s + e.value);
    if (dificiles > 0) {
      _usDificiles += dificiles;
      _conDificiles++;
    }
    _leidosEnLapso += r.codigos.where((c) => !c.sinLeer).length;
    if (_reloj.elapsedMilliseconds >= 2000) _volcarEstadisticas();

    final sinLeer = [
      for (final c in r.codigos)
        if (c.sinLeer) [for (final p in c.esquinas) aVertical(Offset(p.$1, p.$2), sensor, giro)],
    ];
    final codigos = [
      for (final c in r.codigos)
        if (!c.sinLeer)
          CodigoVisto(
          c.texto,
          Simbologia.deMotor(c.bitFormato)?.nombre ?? c.formato,
          [for (final p in c.esquinas) aVertical(Offset(p.$1, p.$2), sensor, giro)],
          simbologia: Simbologia.deMotor(c.bitFormato),
          fuente: 'C++',
          detalle: c.paso.nombre,
          verificado: c.verificado,
          rechazado: c.rechazado,
        ),
    ];

    _linternaAutomatica(r.info, cuadro);
    _zoomAutomatico(r.codigos);
    final confirmados = _fusion.confirmar(codigos);
    final hayAlgo = codigos.isNotEmpty || r.info.regiones > 0;
    if (hayAlgo) {
      _primerVisto ??= DateTime.now();
      _cuadrosSinCodigo = 0;
    } else if (++_cuadrosSinCodigo >= 8) {
      _primerVisto = null;
    }
    for (final d in _fusion.retenidos) {
      registrar('DUDOSO', '${d.valor} ${d.formato} paso=${d.detalle}${d.rechazado ? ' no_calza_con_imagen (no se cuenta)' : ' (se cuenta si se repite en 3 s)'}');
    }
    if (!_capturas.isClosed) {
      _capturas.add(Captura(tamVertical(sensor, giro), confirmados,
          info: r.info, ilegible: r.info.ilegibles > 0, sinLeer: sinLeer, crudos: codigos));
    }
  }

  void _volcarEstadisticas() {
    final seg = _reloj.elapsedMilliseconds / 1000;
    if (_procesados > 0 && seg > 0) {
      final i = ultimaInfo;
      final sensor = _sensorInicio < 0 ? 0 : _ultimoSensor - _sensorInicio;
      final analizados = _ultimoAnalizado - _analizadosInicio;
      registrar('CUADROS', 'en ${seg.toStringAsFixed(1)}s: sensor=$sensor (${(sensor / seg).toStringAsFixed(1)}/s) '
          'analizados=$analizados (${(analizados / seg).toStringAsFixed(1)}/s) con_codigo=$_cuadrosConCodigo '
          'codigos_leidos=$_leidosEnLapso motor prom=${_msMotorTotal ~/ _procesados}ms max=${_msMotorMax}ms '
          'retraso_cuadro prom=${_conEdad == 0 ? '?' : _edadTotal ~/ _conEdad}ms max=${_edadMax}ms '
          '[rapido=${_usRapido ~/ _procesados ~/ 1000}ms opencv=${_usDetector ~/ _procesados ~/ 1000}ms '
          'dificiles=${_conDificiles == 0 ? 0 : _usDificiles ~/ _conDificiles ~/ 1000}ms en $_conDificiles cuadros '
          'gris+redes=${_conRedes == 0 ? 0 : _usRedes ~/ _conRedes ~/ 1000}ms en $_conRedes cuadros]'
          '${i == null ? '' : ' brillo=${i.brillo} contraste=${i.contraste} nitidez=${i.nitidez} reflejo=${i.quemados}%'} '
          'exposicion=${(_expNs / 1e6).toStringAsFixed(1)}ms iso=$_iso $_modoExp '
          'giro prom=${(_giroTotal / _procesados).toStringAsFixed(2)} max=${_giroMax.toStringAsFixed(2)}rad/s '
          'moviendo=$_cuadrosMoviendo '
          'linterna=${linterna ? "si" : "no"} zoom=${aumento.toStringAsFixed(1)}');
    }
    _giroTotal = _giroMax = 0;
    _cuadrosMoviendo = 0;
    _sensorInicio = _ultimoSensor;
    _analizadosInicio = _ultimoAnalizado;
    _procesados = _cuadrosConCodigo = 0;
    _msMotorTotal = _msMotorMax = _edadTotal = _edadMax = _conEdad = _leidosEnLapso = 0;
    _usRapido = _usDetector = _usDificiles = _conDificiles = _usRedes = _conRedes = 0;
    _reloj
      ..reset()
      ..start();
  }

  /// Con poca luz sostenida (~1 s) enciende la linterna sola, si esta activado.
  /// Tambien si la exposicion propia ya esta al tope (ISO maximo y tiempo
  /// largo): sin mas luz la imagen se borronea o se llena de ruido.
  void _linternaAutomatica(InfoMotor info, CuadroNativo cuadro) {
    if (!ajustes.linternaAuto || linterna) return;
    final isoMax = _datos?.isoMax ?? 0;
    final alTope = isoMax > 0 && cuadro.iso >= isoMax * 0.95 && cuadro.exposicionNs >= 6000000;
    // Con exposicion propia la imagen oscura es pasajera mientras el ISO no
    // este al tope (en el A54 se encendio con brillo 47 e ISO 25, v0.16).
    final propia = cuadro.modoExposicion.startsWith('propia');
    final oscuro = info.sugerirLinterna && (!propia || (isoMax > 0 && cuadro.iso >= isoMax * 0.9));
    _cuadrosOscuros = oscuro || alTope ? _cuadrosOscuros + 1 : 0;
    if (_cuadrosOscuros >= 12) {
      _cuadrosOscuros = 0;
      registrar('CAMARA', 'poca luz (brillo ${info.brillo} iso=${cuadro.iso} '
          'exposicion=${(cuadro.exposicionNs / 1e6).toStringAsFixed(1)}ms): linterna automatica');
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
    // Solo al ir a segundo plano: "inactive" llega tambien con el dialogo del
    // permiso de camara, y apagar ahi la reiniciaba al arrancar.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
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
    unawaited(apagar());
    unawaited(_suscripcion?.cancel());
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
        final d = camara.datos;
        if (camara.permisoDenegado) {
          return const _Aviso('Sin permiso de camara. Activalo en Ajustes del telefono > Apps > DIFAR Logistica.');
        }
        if (camara.error != null) return _Aviso('No se pudo abrir la camara (${camara.error}).');
        if (d == null) return const ColoredBox(color: Colors.black);
        final w = d.previaAncho.toDouble(), h = d.previaAlto.toDouble();
        final textura = Texture(key: ValueKey(d.textura), textureId: d.textura);
        // La textura llega en la orientacion del sensor (salvo que ya venga
        // girada); la app esta fija en vertical.
        final Widget previa = d.giroListo
            ? SizedBox(width: h, height: w, child: textura)
            : RotatedBox(quarterTurns: d.giroVista ~/ 90, child: SizedBox(width: w, height: h, child: textura));
        return LayoutBuilder(
          builder: (context, c) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (t) {
              alTocar?.call();
              camara.enfocar(t.localPosition, c.biggest);
            },
            child: ClipRect(
              child: FittedBox(fit: BoxFit.cover, child: previa),
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
