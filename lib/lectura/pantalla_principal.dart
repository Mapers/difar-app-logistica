import 'dart:async';

import 'package:flutter/material.dart';
import 'package:motor_lector/camara_nativa.dart';
import 'package:share_plus/share_plus.dart';

import '../conteo/pantalla_conteo.dart';
import '../core/proyeccion.dart';
import '../core/registro.dart';
import 'ajustes.dart';
import 'aviso_lectura.dart';
import 'camara_comun.dart';
import 'camara_lectora.dart';
import 'fusion.dart';
import 'pantalla_ajustes.dart';
import 'pantalla_lista.dart';
import 'sesion_lectura.dart';

/// Pantalla principal, como SparkScan de Scandit: la lista ocupa la pantalla,
/// la camara es una ventanita flotante (se agranda con un toque) y un boton
/// redondo grande dispara la lectura:
/// * tocar = lee UN codigo (aunque sea el mismo de recien: cada toque cuenta);
/// * mantener presionado = lee seguido, y TODOS los codigos que se ven en la
///   ventanita a la vez (en paralelo), sin repetir el mismo codigo hasta que
///   pase la espera de Ajustes.
/// Con un toque y varios codigos a la vista se lee solo el apuntado (el mas
/// cercano al centro); los demas se marcan "No escaneado".
///
/// La camara queda encendida para que el primer toque lea al instante; se
/// apaga sola tras [_apagarTras] sin usar el boton y se enciende al tocarlo.
class PantallaPrincipal extends StatefulWidget {
  const PantallaPrincipal({super.key, required this.sesion, required this.ajustes});

  final SesionLectura sesion;
  final Ajustes ajustes;

  @override
  State<PantallaPrincipal> createState() => _PantallaPrincipalState();
}

class _PantallaPrincipalState extends State<PantallaPrincipal> {
  static const _apagarTras = Duration(seconds: 30);
  static const _esperaToque = Duration(seconds: 3);
  static const _paraMantener = Duration(milliseconds: 300);

  late final CamaraLectora _camara = CamaraLectora(_ajustes);
  StreamSubscription<Captura>? _capturas;

  /// Consejo sobre la camara ("inclina el telefono", "linterna encendida").
  String? _consejo;
  Timer? _quitarConsejo;

  bool _armado = false;
  bool _sostenido = false;
  bool _dedoAbajo = false;
  bool _apagada = false;
  bool _grande = false;
  bool _ocupada = false; // otra pantalla usa la camara
  String? _resaltado;

  /// Si el disparo actual (toque o mantener) ya leyo algo. Si termina sin
  /// leer nada, suena el aviso de error.
  bool _leyoEnDisparo = false;
  bool _error = false;

  /// Momento en que se toco el boton (para medir cuanto tarda la lectura).
  final _desdeToque = Stopwatch();

  /// Imagen borrosa sostenida mientras se busca: se vuelve a enfocar.
  int _cuadrosBorrosos = 0;
  DateTime _ultimoEnfoque = DateTime.now();

  Timer? _finToque;
  Timer? _detectarMantener;
  Timer? _apagar;
  Timer? _limpiarMarcas;
  Timer? _quitarResaltado;
  Timer? _quitarError;

  Size _tamVista = Size.zero;
  final _cuadro = ValueNotifier<_Cuadro?>(null);

  Ajustes get _ajustes => widget.ajustes;
  SesionLectura get _sesion => widget.sesion;

  @override
  void initState() {
    super.initState();
    _capturas = _camara.capturas.listen(_alDetectar);
    _camara.addListener(_alCambiarCamara);
    unawaited(_camara.iniciar());
    _programarApagado();
  }

  @override
  void dispose() {
    for (final t in [_finToque, _detectarMantener, _apagar, _limpiarMarcas, _quitarResaltado, _quitarError, _quitarConsejo]) {
      t?.cancel();
    }
    unawaited(_capturas?.cancel());
    _camara.removeListener(_alCambiarCamara);
    _camara.dispose();
    _cuadro.dispose();
    super.dispose();
  }

  void _alCambiarCamara() {
    if (_camara.linternaAutomatica) {
      _camara.linternaAutomatica = false;
      _mostrarConsejo('Poca luz: linterna encendida');
    }
  }

  void _mostrarConsejo(String texto) {
    if (!mounted) return;
    setState(() => _consejo = texto);
    _quitarConsejo?.cancel();
    _quitarConsejo = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _consejo = null);
    });
  }

  // ---------------------------------------------------------------- disparo

  void _alPresionar() {
    _dedoAbajo = true;
    _encender();
    setState(() {
      _armado = true;
      _sostenido = false;
      _error = false;
    });
    _leyoEnDisparo = false;
    _camara.esfuerzo = true; // todos los pasos del motor mientras se busca
    _cuadrosBorrosos = 0;
    // Sin forzar el enfoque: enfocar un punto traba el foco ~5 s en Android y
    // con re-enfoques seguidos la camara "barria" y salia borrosa (registro
    // v0.8). Queda el enfoque automatico continuo.
    _ultimoEnfoque = DateTime.now();
    _desdeToque
      ..reset()
      ..start();
    _finToque?.cancel();
    _detectarMantener?.cancel();
    _detectarMantener = Timer(_paraMantener, () {
      if (_dedoAbajo && mounted) {
        // Si el toque ya termino (leyo o aviso "ilegible") pero el dedo sigue
        // en el boton, se vuelve a armar: antes quedaba en "mantener" sin leer
        // nada (registro v0.8: 30 s con codigos a la vista sin lecturas).
        _finToque?.cancel();
        setState(() {
          _sostenido = true;
          _armado = true;
        });
        _camara.esfuerzo = true;
        _camara.buscarTodos = true; // el motor busca todos los del cuadro
        registrar('DISPARO', 'mantener (todos los visibles)');
      }
    });
  }

  void _alSoltar() {
    _dedoAbajo = false;
    _detectarMantener?.cancel();
    if (_sostenido) {
      if (!_leyoEnDisparo) _noSeLeyo('No se leyo ningun codigo');
      _desarmar();
    } else if (_armado) {
      // Toque corto: queda esperando un codigo unos segundos.
      _finToque = Timer(_esperaToque, () {
        if (!_leyoEnDisparo) _noSeLeyo('No se leyo ningun codigo');
        _desarmar();
      });
    }
  }

  /// Aviso de error: tono grave doble, doble vibracion, borde rojo y mensaje.
  void _noSeLeyo(String motivo) {
    if (!mounted) return;
    final i = _camara.ultimaInfo;
    registrar('FALLO', '$motivo tras ${_desdeToque.elapsedMilliseconds}ms '
        '(${_sostenido ? "mantener" : "toque"})'
        '${i == null ? '' : ' brillo=${i.brillo} contraste=${i.contraste} nitidez=${i.nitidez} reflejo=${i.quemados}% pasos=${i.pasos}'}'
        ' linterna=${_camara.linterna ? "si" : "no"}');
    unawaited(AvisoLectura.fallo(sonido: _ajustes.sonido, vibrar: _ajustes.vibrar));
    setState(() => _error = true);
    _quitarError?.cancel();
    _quitarError = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _error = false);
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$motivo. Acerca la camara, limpia la etiqueta o ingresalo a mano.'),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _desarmar() {
    _finToque?.cancel();
    _camara.buscarTodos = false;
    _camara.esfuerzo = false;
    if (!mounted) return;
    setState(() {
      _armado = false;
      _sostenido = false;
    });
    _programarApagado();
  }

  void _encender() {
    _apagar?.cancel();
    if (_apagada && !_ocupada) {
      setState(() => _apagada = false);
      unawaited(_camara.iniciar());
    }
  }

  void _programarApagado() {
    _apagar?.cancel();
    _apagar = Timer(_apagarTras, () {
      if (!mounted || _armado || _ocupada) return;
      setState(() => _apagada = true);
      _cuadro.value = null;
      unawaited(_camara.apagar());
    });
  }

  // ---------------------------------------------------------------- lectura

  void _alDetectar(Captura captura) {
    final vistos = captura.codigos;
    final apuntado = indiceApuntado([for (final v in vistos) v.esquinas], captura.imagen, _tamVista);

    final leidos = <int, ResultadoLectura>{};
    ResultadoLectura? leido;
    if (_armado && _sostenido) {
      // Mantener: todos los visibles a la vez, un solo aviso por grupo.
      _sesion.espera = Duration(milliseconds: _ajustes.esperaMs);
      final ahora = DateTime.now();
      final visibles = indicesVisibles([for (final v in vistos) v.esquinas], captura.imagen, _tamVista);
      for (final k in visibles) {
        final r = _sesion.registrar(vistos[k].valor, vistos[k].formato, ahora, sumarRepetidos: _ajustes.sumarRepetidos);
        if (r != ResultadoLectura.ignorado) leidos[k] = r;
      }
      if (leidos.isNotEmpty) {
        for (final e in leidos.entries) {
          _registrarLectura(vistos[e.key], e.value, captura, grupo: leidos.length);
        }
        final hayNuevo = leidos.values.contains(ResultadoLectura.nuevo);
        _avisarLectura(vistos[leidos.keys.first].valor, hayNuevo ? ResultadoLectura.nuevo : ResultadoLectura.sumado);
        leido = hayNuevo ? ResultadoLectura.nuevo : ResultadoLectura.sumado;
      }
    } else if (_armado && apuntado != null) {
      final v = vistos[apuntado];
      _sesion.espera = Duration(milliseconds: _ajustes.esperaMs);
      leido = _sesion.registrar(v.valor, v.formato, DateTime.now(),
          sumarRepetidos: _ajustes.sumarRepetidos,
          // Cada toque es intencional: cuenta aunque sea el mismo de recien.
          forzar: !_sostenido);
      // Toque sobre un codigo que ya esta y "Sumar repetidos" apagado: se
      // leyo bien, solo no se suma. Aviso suave, no de error.
      final efectivo = leido == ResultadoLectura.ignorado ? ResultadoLectura.sumado : leido;
      _registrarLectura(v, efectivo, captura);
      _avisarLectura(v.valor, efectivo);
      leidos[apuntado] = efectivo;
    } else if (_armado && !_leyoEnDisparo && apuntado == null && captura.ilegible) {
      // La camara ve un codigo pero no puede decodificar su contenido.
      _leyoEnDisparo = true; // un solo aviso por disparo
      _noSeLeyo('Codigo ilegible');
      if (!_sostenido && !_dedoAbajo) _desarmar();
    }

    // Borrosa varios cuadros seguidos mientras se busca: enfocar de nuevo el
    // centro y pedir quietud (la nitidez sube a 7-9 cuando se lee).
    if (_armado && leidos.isEmpty) {
      final n = captura.info?.nitidez ?? 10;
      _cuadrosBorrosos = n <= 4 ? _cuadrosBorrosos + 1 : 0;
      final ahora = DateTime.now();
      // ~3 s borrosa: reiniciar el enfoque automatico continuo (sin trabarlo).
      if (_cuadrosBorrosos >= 25 && ahora.difference(_ultimoEnfoque) > const Duration(seconds: 3)) {
        _cuadrosBorrosos = 0;
        _ultimoEnfoque = ahora;
        unawaited(_camara.reiniciarEnfoque());
        if (_consejo == null) _mostrarConsejo('Enfocando: manten quieto el telefono');
        registrar('ENFOQUE', 'imagen borrosa (nitidez $n) 3 s: reiniciar enfoque automatico');
      }
    }

    // Reflejo fuerte mientras se intenta leer: ninguna preparacion recupera
    // barras quemadas, hay que cambiar el angulo.
    if (_armado && leido == null && (captura.info?.quemados ?? 0) >= 8 && _consejo == null) {
      _mostrarConsejo('Reflejo: inclina un poco el telefono');
      registrar('CONSEJO', 'reflejo ${captura.info?.quemados}%: inclinar el telefono');
    }

    _cuadro.value = _Cuadro(captura.imagen, vistos, apuntado, leidos, todos: _armado && _sostenido);
    _limpiarMarcas?.cancel();
    _limpiarMarcas = Timer(const Duration(milliseconds: 350), () => _cuadro.value = null);
  }

  void _registrarLectura(CodigoVisto v, ResultadoLectura r, Captura captura, {int grupo = 1}) {
    final i = captura.info;
    registrar('LECTURA', '${v.valor} ${v.formato}'
        '${v.detalle.isNotEmpty ? " paso=${v.detalle}" : ""} '
        '${r == ResultadoLectura.nuevo ? "nuevo" : "sumado"} visible_hace=${_camara.msVisible ?? 0}ms '
        'desde_lectura_anterior=${_desdeToque.elapsedMilliseconds}ms '
        '(${_sostenido ? "mantener" : "toque"}) a_la_vista=${captura.codigos.length} juntos=$grupo '
        '${tamanoCodigo(v)} imagen=${captura.imagen.width.toInt()}x${captura.imagen.height.toInt()}'
        '${i == null ? '' : ' brillo=${i.brillo} nitidez=${i.nitidez} reflejo=${i.quemados}% '
            'motor=${i.microsegundos ~/ 1000}ms hilos=${i.hilos}'
            '${i.regiones >= 0 ? ' opencv_ubico=${i.regiones}' : ''}'}');
  }

  /// Pitido, vibracion y resaltado (uno por lectura o por grupo de lecturas).
  void _avisarLectura(String valor, ResultadoLectura r) {
    _leyoEnDisparo = true;
    _camara.reiniciarVisible();
    _desdeToque
      ..reset()
      ..start();
    unawaited(AvisoLectura.leido(
      sonido: _ajustes.sonido,
      vibrar: _ajustes.vibrar,
      repetido: r == ResultadoLectura.sumado,
    ));
    setState(() => _resaltado = valor);
    _quitarResaltado?.cancel();
    _quitarResaltado = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _resaltado = null);
    });
    if (!_sostenido) _desarmar();
  }

  // ---------------------------------------------------------------- navegacion

  /// Libera la camara mientras otra pantalla la usa y la retoma al volver.
  Future<void> _abrir(Widget pantalla) async {
    _ocupada = true;
    _desarmar();
    _cuadro.value = null;
    await _camara.apagar();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => pantalla));
    if (!mounted) return;
    _ocupada = false;
    // Al volver toma los ajustes nuevos (formatos, motor).
    await _camara.iniciar();
    if (!mounted) return;
    setState(() => _apagada = false);
    _programarApagado();
  }

  Future<void> _compartirRegistro() async {
    final archivo = await Registro.instancia.paraCompartir();
    if (!mounted) return;
    if (archivo == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay registro todavia.')));
      return;
    }
    // Con el registro van los cuadros de diagnostico (codigos que no se leyeron).
    var cuadros = <String>[];
    try {
      cuadros = await CamaraNativa.archivosDiagnostico();
    } catch (_) {}
    registrar('REGISTRO', 'compartido con ${cuadros.where((c) => c.endsWith('.jpg')).length} cuadros de diagnostico');
    await SharePlus.instance.share(ShareParams(
      files: [XFile(archivo.path, mimeType: 'text/plain'), for (final c in cuadros) XFile(c)],
      subject: 'Registro del lector DIFAR',
    ));
  }

  Future<void> _borrarRegistro() async {
    await Registro.instancia.borrar();
    try {
      await CamaraNativa.borrarDiagnostico();
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registro borrado.')));
  }

  Future<void> _ingresoManual() async {
    final codigo = await showDialog<String>(context: context, builder: (_) => const DialogoManual());
    if (codigo == null || codigo.isEmpty) return;
    _sesion.registrar(codigo, 'Manual', DateTime.now(), forzar: true);
    registrar('MANUAL', codigo);
    setState(() => _resaltado = codigo);
  }

  // ---------------------------------------------------------------- vista

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _sesion,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('DIFAR Logistica'),
              Text(
                '${_sesion.items.length} codigos · ${_sesion.totalUnidades} unidades',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Conteo (MatrixScan Count)',
            onPressed: () => _abrir(PantallaConteo(sesion: _sesion, ajustes: _ajustes)),
            icon: const Icon(Icons.grid_view),
          ),
          PopupMenuButton<String>(
            onSelected: (op) => switch (op) {
              'manual' => _ingresoManual(),
              'csv' => compartirCsv(_sesion),
              'vaciar' => confirmarVaciar(context, _sesion),
              'registro' => _compartirRegistro(),
              'borrar_registro' => _borrarRegistro(),
              _ => _abrir(PantallaAjustes(ajustes: _ajustes)),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'manual', child: Text('Ingresar codigo a mano')),
              PopupMenuItem(value: 'csv', child: Text('Compartir CSV')),
              PopupMenuItem(value: 'vaciar', child: Text('Vaciar lista')),
              PopupMenuItem(value: 'ajustes', child: Text('Ajustes')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'registro', child: Text('Compartir registro (log)')),
              PopupMenuItem(value: 'borrar_registro', child: Text('Borrar registro')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final ancho = _grande ? c.maxWidth - 24 : c.maxWidth * 0.42;
        final alto = _grande ? c.maxHeight * 0.5 : ancho;
        return Stack(
          children: [
            Positioned.fill(
              child: ListaLecturas(
                sesion: _sesion,
                resaltado: _resaltado,
                // Que la ultima fila no quede bajo el boton.
                relleno: const EdgeInsets.only(bottom: 120),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              top: 12,
              right: 12,
              width: ancho,
              height: alto,
              child: _ventanaCamara(),
            ),
            Positioned(right: 20, bottom: 28, child: _botonDisparo()),
            // Varias cajas a la vez, camara a pantalla completa (como los SDK
            // comerciales); al terminar se agregan a la lista.
            Positioned(
              left: 16,
              bottom: 40,
              child: FloatingActionButton.extended(
                heroTag: 'varios',
                onPressed: () => _abrir(PantallaConteo(sesion: _sesion, ajustes: _ajustes, sinLista: true)),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Escanear varios'),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _ventanaCamara() {
    return Material(
      elevation: 8,
      color: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: _error ? const BorderSide(color: Colors.redAccent, width: 4) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        _tamVista = c.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            VistaCamara(camara: _camara),
            IgnorePointer(
              child: ValueListenableBuilder(
                valueListenable: _cuadro,
                builder: (context, cuadro, _) =>
                    CustomPaint(painter: _MarcasApuntado(cuadro, armado: _armado)),
              ),
            ),
            if (_apagada)
              GestureDetector(
                onTap: _encender,
                child: const ColoredBox(
                  color: Color(0xFF3A3A3A),
                  child: Center(child: Icon(Icons.qr_code_scanner, color: Colors.white54, size: 36)),
                ),
              ),
            Positioned(
              top: 4,
              left: 4,
              child: ListenableBuilder(
                listenable: _camara,
                builder: (context, _) => BotonSobreCamara(
                  icono: _camara.linterna ? Icons.flash_on : Icons.flash_off,
                  tooltip: 'Linterna',
                  onPressed: _camara.lista ? _camara.cambiarLinterna : null,
                ),
              ),
            ),
            if (_consejo != null)
              Positioned(
                left: 6,
                right: 6,
                bottom: 40,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                  child: Text(_consejo!,
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: BotonSobreCamara(
                icono: _grande ? Icons.close_fullscreen : Icons.open_in_full,
                tooltip: _grande ? 'Achicar' : 'Agrandar',
                onPressed: () => setState(() => _grande = !_grande),
              ),
            ),
            Positioned(
              bottom: 4,
              right: 4,
              child: ListenableBuilder(
                listenable: _camara,
                builder: (context, _) {
                  final cerca = _camara.aumento > 1.2;
                  return TextButton(
                    onPressed: () => _camara.fijarAumento(cerca ? 1 : 2),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.black45,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(40, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(cerca ? '2x' : '1x'),
                  );
                },
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _botonDisparo() {
    final colores = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Escanear. Toca para leer un codigo, manten presionado para leer seguido.',
      child: Listener(
        onPointerDown: (_) => _alPresionar(),
        onPointerUp: (_) => _alSoltar(),
        onPointerCancel: (_) => _alSoltar(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _armado ? colores.primary : const Color(0xFF6E6E6E),
            border: Border.all(
              color: _sostenido ? Colors.greenAccent : Colors.white,
              width: _armado ? 5 : 3,
            ),
            boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black38, offset: Offset(0, 4))],
          ),
          child: const Icon(Icons.barcode_reader, color: Colors.white, size: 38),
        ),
      ),
    );
  }
}

class _Cuadro {
  _Cuadro(this.imagen, this.vistos, this.apuntado, this.leidos, {this.todos = false});

  final Size imagen;
  final List<CodigoVisto> vistos;
  final int? apuntado;

  /// Indice en [vistos] -> como se conto en este cuadro.
  final Map<int, ResultadoLectura> leidos;

  /// Manteniendo: se leen todos (no hay "No escaneado").
  final bool todos;
}

/// Con un toque marca el codigo apuntado (blanco; verde/ambar al leerlo) y,
/// si hay mas de uno, deja los otros en gris con "No escaneado". Manteniendo
/// presionado marca todos, verde/ambar los que se contaron.
class _MarcasApuntado extends CustomPainter {
  _MarcasApuntado(this.cuadro, {required this.armado});

  final _Cuadro? cuadro;
  final bool armado;

  @override
  void paint(Canvas canvas, Size size) {
    final c = cuadro;
    if (c == null) return;
    for (var i = 0; i < c.vistos.length; i++) {
      final puntos = proyectarACubrir(c.vistos[i].esquinas, c.imagen, size);
      if (puntos.length < 4) continue;
      final esApuntado = c.todos || i == c.apuntado;
      final leido = c.leidos[i];
      final color = !esApuntado
          ? Colors.white38
          : switch (leido) {
              ResultadoLectura.nuevo => Colors.greenAccent,
              ResultadoLectura.sumado => Colors.amber,
              _ => armado ? Colors.white : Colors.white70,
            };
      final forma = Path()..addPolygon(puntos, true);
      if (esApuntado && leido != null) {
        canvas.drawPath(forma, Paint()..color = color.withValues(alpha: 0.35));
      }
      canvas.drawPath(
        forma,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = esApuntado ? 3 : 1.5,
      );
      if (!esApuntado && c.vistos.length > 1) _etiqueta(canvas, puntos, 'No escaneado');
    }
  }

  void _etiqueta(Canvas canvas, List<Offset> puntos, String texto) {
    final tp = TextPainter(
      text: TextSpan(text: texto, style: const TextStyle(color: Colors.white, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    final centro = centroDe(puntos);
    final caja = Rect.fromCenter(center: centro, width: tp.width + 8, height: tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(caja, const Radius.circular(4)), Paint()..color = Colors.black54);
    tp.paint(canvas, caja.topLeft + const Offset(4, 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(_MarcasApuntado old) => old.cuadro != cuadro || old.armado != armado;
}
