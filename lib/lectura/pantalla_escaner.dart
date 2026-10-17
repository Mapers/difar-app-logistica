import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/codigos.dart';
import '../core/proyeccion.dart';
import 'ajustes.dart';
import 'aviso_lectura.dart';
import 'pantalla_ajustes.dart';
import 'pantalla_lista.dart';
import 'sesion_lectura.dart';

/// Pantalla principal: camara a pantalla completa con una ventana de lectura.
///
/// Lo que la hace rapida:
/// * solo se decodifican los formatos del grupo elegido en Ajustes;
/// * solo se analiza la zona de la ventana (`scanWindow`), no todo el cuadro;
/// * `DetectionSpeed.unrestricted` analiza todos los cuadros y los repetidos
///   los filtra [SesionLectura] (asi un codigo nuevo se lee al instante);
/// * resolucion 1280x720 en Android (la de fabrica, 640x480, no alcanza para
///   codigos chicos o lejanos) y autozoom opcional.
///
/// Modo Multi (como MatrixScan): sin ventana, cada cuadro puede traer varios
/// codigos; todos se cuentan a la vez (una sola vez cada uno mientras sigan a
/// la vista) y se marcan encima de la imagen con su cantidad.
class PantallaEscaner extends StatefulWidget {
  const PantallaEscaner({super.key, required this.sesion, required this.ajustes});

  final SesionLectura sesion;
  final Ajustes ajustes;

  @override
  State<PantallaEscaner> createState() => _PantallaEscanerState();
}

class _PantallaEscanerState extends State<PantallaEscaner> {
  late MobileScannerController _camara;
  late GrupoFormatos _grupoCamara;
  late bool _autoZoomCamara;
  late bool _multiCamara;

  /// Codigos del ultimo cuadro en modo Multi, para dibujarlos encima.
  final _cuadroMulti = ValueNotifier<_CuadroMulti?>(null);
  Timer? _limpiarMulti;

  ItemLeido? _ultimo;
  ResultadoLectura? _ultimoResultado;
  bool _destello = false;
  bool _enPausa = false;
  double _zoom = 0;
  Timer? _apagarDestello;

  Ajustes get _ajustes => widget.ajustes;

  @override
  void initState() {
    super.initState();
    _camara = _crearCamara();
  }

  MobileScannerController _crearCamara() {
    _grupoCamara = _ajustes.grupo;
    _autoZoomCamara = _ajustes.autoZoom;
    _multiCamara = _ajustes.modo == ModoLectura.multi;
    return MobileScannerController(
      formats: _grupoCamara.formatos,
      detectionSpeed: DetectionSpeed.unrestricted,
      // En Multi los codigos salen mas chicos (hay varios en el cuadro): mas resolucion.
      cameraResolution: _multiCamara ? const Size(1920, 1080) : const Size(1280, 720),
      autoZoom: _autoZoomCamara,
    );
  }

  @override
  void dispose() {
    _apagarDestello?.cancel();
    _limpiarMulti?.cancel();
    _cuadroMulti.dispose();
    unawaited(_camara.dispose());
    super.dispose();
  }

  void _alDetectar(BarcodeCapture captura) {
    if (_enPausa) return;
    if (_multiCamara) return _alDetectarMulti(captura);
    for (final b in captura.barcodes) {
      final valor = b.rawValue;
      if (valor == null || valor.isEmpty) continue;
      _registrar(valor, nombreFormato(b.format));
      if (_ajustes.modo == ModoLectura.unoAUno) break;
    }
  }

  void _alDetectarMulti(BarcodeCapture captura) {
    widget.sesion.espera = Duration(milliseconds: _ajustes.esperaMs);
    final ahora = DateTime.now();
    final marcas = <_Marca>[];
    var nuevos = 0;
    var sumados = 0;
    for (final b in captura.barcodes) {
      final valor = b.rawValue;
      if (valor == null || valor.isEmpty) continue;
      final r = widget.sesion.registrar(valor, nombreFormato(b.format), ahora,
          sumarRepetidos: _ajustes.sumarRepetidos);
      if (r == ResultadoLectura.nuevo) nuevos++;
      if (r == ResultadoLectura.sumado) sumados++;
      if (b.corners.length == 4) {
        marcas.add(_Marca(valor, b.corners, r == ResultadoLectura.ignorado ? null : r));
      }
    }
    _cuadroMulti.value = _CuadroMulti(captura.size, marcas, widget.sesion.cantidades);
    // Si la camara deja de ver codigos, se borran las marcas.
    _limpiarMulti?.cancel();
    _limpiarMulti = Timer(const Duration(milliseconds: 350), () => _cuadroMulti.value = null);

    if (nuevos + sumados == 0) return;
    // Un solo pitido por cuadro, aunque entren varios codigos juntos.
    unawaited(AvisoLectura.leido(
      sonido: _ajustes.sonido,
      vibrar: _ajustes.vibrar,
      repetido: nuevos == 0,
    ));
    setState(() {
      _ultimo = widget.sesion.items.first;
      _ultimoResultado = nuevos > 0 ? ResultadoLectura.nuevo : ResultadoLectura.sumado;
    });
  }

  void _registrar(String valor, String formato) {
    widget.sesion.espera = Duration(milliseconds: _ajustes.esperaMs);
    final r = widget.sesion.registrar(valor, formato, DateTime.now(),
        sumarRepetidos: _ajustes.sumarRepetidos);
    if (r == ResultadoLectura.ignorado) return;

    unawaited(AvisoLectura.leido(
      sonido: _ajustes.sonido,
      vibrar: _ajustes.vibrar,
      repetido: r == ResultadoLectura.sumado,
    ));
    setState(() {
      _ultimo = widget.sesion.items.first;
      _ultimoResultado = r;
      _destello = true;
    });
    _apagarDestello?.cancel();
    _apagarDestello = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _destello = false);
    });

    if (_ajustes.modo == ModoLectura.unoAUno) {
      setState(() => _enPausa = true);
      unawaited(_camara.pause());
    }
  }

  Future<void> _seguir() async {
    setState(() => _enPausa = false);
    await _camara.start();
  }

  /// Abre otra pantalla con la camara pausada (ahorra bateria y evita lecturas
  /// fantasma) y la reanuda al volver.
  Future<void> _abrir(Widget pantalla) async {
    await _camara.pause();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => pantalla));
    if (!mounted) return;
    if (!await _recrearSiCambio() && !_enPausa) await _camara.start();
  }

  /// Formatos, autozoom y entrar/salir de Multi se fijan al crear la camara:
  /// si cambiaron, se recrea. Devuelve true si la recreo.
  Future<bool> _recrearSiCambio() async {
    final multi = _ajustes.modo == ModoLectura.multi;
    if (_grupoCamara == _ajustes.grupo && _autoZoomCamara == _ajustes.autoZoom && _multiCamara == multi) {
      return false;
    }
    final vieja = _camara;
    _cuadroMulti.value = null;
    setState(() {
      _camara = _crearCamara();
      _zoom = 0;
      _enPausa = false;
    });
    await vieja.dispose();
    return true;
  }

  Future<void> _cambiarModo(ModoLectura modo) async {
    _ajustes.modo = modo;
    if (await _recrearSiCambio()) return;
    if (_enPausa && modo != ModoLectura.unoAUno) await _seguir();
    setState(() {});
  }

  Future<void> _ingresoManual() async {
    final codigo = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoManual(),
    );
    if (codigo == null || codigo.isEmpty) return;
    // El ingreso manual siempre cuenta, aunque se haya leido hace un instante.
    widget.sesion.registrar(codigo, 'Manual', DateTime.now(), forzar: true);
    setState(() {
      _ultimo = widget.sesion.items.first;
      _ultimoResultado = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, c) {
        final ventana = ventanaLectura(c.biggest, _grupoCamara);
        return Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              key: ObjectKey(_camara),
              controller: _camara,
              scanWindow: _multiCamara ? null : ventana,
              tapToFocus: true,
              onDetect: _alDetectar,
              errorBuilder: (context, error) => _ErrorCamara(error: error),
            ),
            if (_multiCamara)
              IgnorePointer(
                child: ValueListenableBuilder(
                  valueListenable: _cuadroMulti,
                  builder: (context, cuadro, _) => CustomPaint(painter: _MarcasMulti(cuadro)),
                ),
              )
            else ...[
              IgnorePointer(
                child: CustomPaint(
                  painter: _MarcoLectura(
                    ventana: ventana,
                    color: _destello
                        ? (_ultimoResultado == ResultadoLectura.sumado ? Colors.amber : Colors.greenAccent)
                        : Colors.white,
                  ),
                ),
              ),
              if (!_enPausa) _Laser(ventana: ventana),
            ],
            SafeArea(
              child: Column(
                children: [
                  _barraSuperior(),
                  SegmentedButton<ModoLectura>(
                    segments: [
                      for (final m in ModoLectura.values)
                        ButtonSegment(value: m, label: Text(m.etiqueta)),
                    ],
                    selected: {_ajustes.modo},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _cambiarModo(s.first),
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Colors.black45,
                      foregroundColor: Colors.white,
                      selectedBackgroundColor: Colors.white,
                      selectedForegroundColor: Colors.black,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  if (_multiCamara)
                    ValueListenableBuilder(
                      valueListenable: _cuadroMulti,
                      builder: (context, cuadro, _) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          cuadro == null || cuadro.marcas.isEmpty
                              ? 'Apunta a varios codigos a la vez'
                              : '${cuadro.marcas.length} codigos a la vista',
                          style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(child: _panelInferior()),
            ),
          ],
        );
      }),
    );
  }

  Widget _barraSuperior() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Text('DIFAR Logistica',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          ValueListenableBuilder(
            valueListenable: _camara,
            builder: (context, estado, _) => _BotonCircular(
              icono: estado.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off,
              tooltip: 'Linterna',
              onPressed: estado.torchState == TorchState.unavailable ? null : _camara.toggleTorch,
            ),
          ),
          _BotonCircular(icono: Icons.keyboard, tooltip: 'Ingresar a mano', onPressed: _ingresoManual),
          _BotonCircular(
            icono: Icons.tune,
            tooltip: 'Ajustes',
            onPressed: () => _abrir(PantallaAjustes(ajustes: _ajustes)),
          ),
        ],
      ),
    );
  }

  Widget _panelInferior() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.zoom_out, color: Colors.white70),
              Expanded(
                child: Slider(
                  value: _zoom,
                  onChanged: (v) {
                    setState(() => _zoom = v);
                    _camara.setZoomScale(v);
                  },
                ),
              ),
              const Icon(Icons.zoom_in, color: Colors.white70),
            ],
          ),
          if (_ultimo != null) _TarjetaUltimo(item: _ultimo!, resultado: _ultimoResultado),
          if (_enPausa)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _seguir,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Leer otro'),
                ),
              ),
            ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: widget.sesion,
            builder: (context, _) => SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _abrir(PantallaLista(sesion: widget.sesion)),
                icon: const Icon(Icons.list_alt),
                label: Text(
                  '${widget.sesion.items.length} codigos · ${widget.sesion.totalUnidades} unidades',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ventana de lectura: ancha y baja para codigos 1D (se apunta mas rapido),
/// cuadrada para codigos 2D.
Rect ventanaLectura(Size pantalla, GrupoFormatos grupo) {
  final ancho = pantalla.width * 0.86;
  final alto = grupo == GrupoFormatos.dosD ? ancho * 0.8 : ancho * 0.5;
  return Rect.fromCenter(
    center: Offset(pantalla.width / 2, pantalla.height * 0.42),
    width: ancho,
    height: alto,
  );
}

class _Marca {
  _Marca(this.valor, this.esquinas, this.resultado);

  final String valor;
  final List<Offset> esquinas;

  /// null = ya estaba contado y sigue a la vista.
  final ResultadoLectura? resultado;
}

class _CuadroMulti {
  _CuadroMulti(this.imagen, this.marcas, this.cantidades);

  final Size imagen;
  final List<_Marca> marcas;
  final Map<String, int> cantidades;
}

/// Dibuja cada codigo visible: verde = recien contado, ambar = sumado,
/// azul = ya contado (sigue a la vista). Etiqueta con la cantidad.
class _MarcasMulti extends CustomPainter {
  _MarcasMulti(this.cuadro);

  final _CuadroMulti? cuadro;

  @override
  void paint(Canvas canvas, Size size) {
    final c = cuadro;
    if (c == null) return;
    for (final m in c.marcas) {
      final puntos = proyectarACubrir(m.esquinas, c.imagen, size);
      if (puntos.length != 4) continue;
      final color = switch (m.resultado) {
        ResultadoLectura.nuevo => Colors.greenAccent,
        ResultadoLectura.sumado => Colors.amber,
        _ => Colors.lightBlueAccent,
      };
      final forma = Path()..addPolygon(puntos, true);
      canvas.drawPath(forma, Paint()..color = color.withValues(alpha: 0.3));
      canvas.drawPath(
        forma,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );

      final texto = TextPainter(
        text: TextSpan(
          text: '${m.valor}  x${c.cantidades[m.valor] ?? 0}',
          style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 220);
      final arriba = puntos.reduce((a, b) => a.dy < b.dy ? a : b);
      final centroX = puntos.map((p) => p.dx).reduce((a, b) => a + b) / 4;
      final caja = Rect.fromCenter(
        center: Offset(centroX, arriba.dy - texto.height / 2 - 8),
        width: texto.width + 12,
        height: texto.height + 6,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(caja, const Radius.circular(6)), Paint()..color = color);
      texto.paint(canvas, caja.topLeft + const Offset(6, 3));
      texto.dispose();
    }
  }

  @override
  bool shouldRepaint(_MarcasMulti old) => old.cuadro != cuadro;
}

class _MarcoLectura extends CustomPainter {
  _MarcoLectura({required this.ventana, required this.color});

  final Rect ventana;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final marco = RRect.fromRectAndRadius(ventana, const Radius.circular(16));
    // Oscurece todo lo que esta fuera de la ventana.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(marco),
      ),
      Paint()..color = Colors.black54,
    );
    canvas.drawRRect(
      marco,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = color == Colors.white ? 2 : 5,
    );
  }

  @override
  bool shouldRepaint(_MarcoLectura old) => old.ventana != ventana || old.color != color;
}

class _Laser extends StatefulWidget {
  const _Laser({required this.ventana});

  final Rect ventana;

  @override
  State<_Laser> createState() => _LaserState();
}

class _LaserState extends State<_Laser> with SingleTickerProviderStateMixin {
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.ventana;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Positioned(
        left: v.left + 12,
        width: v.width - 24,
        top: v.top + 8 + (v.height - 16) * _anim.value,
        height: 2,
        child: const IgnorePointer(child: ColoredBox(color: Colors.redAccent)),
      ),
    );
  }
}

class _TarjetaUltimo extends StatelessWidget {
  const _TarjetaUltimo({required this.item, required this.resultado});

  final ItemLeido item;
  final ResultadoLectura? resultado;

  @override
  Widget build(BuildContext context) {
    final sumado = resultado == ResultadoLectura.sumado;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: sumado ? Colors.amber : Colors.green,
          foregroundColor: Colors.black,
          child: Icon(sumado ? Icons.add : Icons.check),
        ),
        title: Text(item.codigo,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
        subtitle: Text(item.formato),
        trailing: Text('x${item.cantidad}', style: Theme.of(context).textTheme.titleLarge),
      ),
    );
  }
}

class _BotonCircular extends StatelessWidget {
  const _BotonCircular({required this.icono, required this.tooltip, required this.onPressed});

  final IconData icono;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icono),
      color: Colors.white,
      style: IconButton.styleFrom(backgroundColor: Colors.black38),
    );
  }
}

class _ErrorCamara extends StatelessWidget {
  const _ErrorCamara({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final texto = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? 'Sin permiso de camara. Activalo en Ajustes del telefono > Apps > DIFAR Logistica.'
        : 'No se pudo abrir la camara (${error.errorCode.name}).';
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }
}

class _DialogoManual extends StatefulWidget {
  const _DialogoManual();

  @override
  State<_DialogoManual> createState() => _DialogoManualState();
}

class _DialogoManualState extends State<_DialogoManual> {
  final _texto = TextEditingController();
  String? _aviso;

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  void _aceptar() {
    final codigo = _texto.text.trim();
    if (codigo.isEmpty) return;
    // Si parece un EAN/UPC/GTIN, se avisa una vez si el digito verificador no cuadra.
    final esGtin = RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(codigo);
    if (esGtin && !digitoGs1Valido(codigo) && _aviso == null) {
      setState(() => _aviso = 'El digito verificador no coincide. Revisa el codigo o toca Agregar otra vez.');
      return;
    }
    Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingresar codigo'),
      content: TextField(
        controller: _texto,
        autofocus: true,
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(labelText: 'Codigo', errorText: _aviso, errorMaxLines: 3),
        onChanged: (_) {
          if (_aviso != null) setState(() => _aviso = null);
        },
        onSubmitted: (_) => _aceptar(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _aceptar, child: const Text('Agregar')),
      ],
    );
  }
}
