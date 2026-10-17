import 'dart:async';

import 'package:flutter/material.dart';

import '../core/proyeccion.dart';
import 'ajustes.dart';
import 'aviso_lectura.dart';
import 'camara_comun.dart';
import 'camara_lectora.dart';
import 'fusion.dart';
import 'sesion_lectura.dart';

/// Conteo multiple, como MatrixScan Count de Scandit: camara a pantalla
/// completa, un punto sobre cada codigo visible y un disparador que cuenta
/// TODOS los que se ven de una sola vez (pallet, estanteria, caja con varias
/// etiquetas). Lo contado queda en verde y no se vuelve a contar en este
/// conteo. Con "Auto" cuenta solo, sin tocar el disparador.
class PantallaMulti extends StatefulWidget {
  const PantallaMulti({super.key, required this.sesion, required this.ajustes});

  final SesionLectura sesion;
  final Ajustes ajustes;

  @override
  State<PantallaMulti> createState() => _PantallaMultiState();
}

class _PantallaMultiState extends State<PantallaMulti> {
  late final CamaraLectora _camara = CamaraLectora(widget.ajustes, multiple: true);
  StreamSubscription<Captura>? _capturas;

  /// Lo visto en los ultimos [_memoria]: cada cuadro (y cada motor) puede
  /// traer un grupo algo distinto; juntarlos evita que las marcas parpadeen.
  static const _memoria = Duration(milliseconds: 400);
  final _recientes = <String, (CodigoVisto, DateTime)>{};

  /// Contados en este conteo (aunque ya estuvieran en la lista de antes).
  final _contados = <String>{};
  final _cuadro = ValueNotifier<_CuadroMulti?>(null);
  Timer? _limpiar;
  bool _auto = false;
  int? _ultimoLote;
  Timer? _ocultarLote;

  @override
  void initState() {
    super.initState();
    _capturas = _camara.capturas.listen(_alDetectar);
    unawaited(_camara.iniciar());
  }

  @override
  void dispose() {
    _limpiar?.cancel();
    _ocultarLote?.cancel();
    unawaited(_capturas?.cancel());
    _camara.dispose();
    _cuadro.dispose();
    super.dispose();
  }

  void _alDetectar(Captura captura) {
    final ahora = DateTime.now();
    for (final c in captura.codigos) {
      _recientes[c.valor] = (c, ahora);
    }
    _recientes.removeWhere((_, v) => ahora.difference(v.$2) > _memoria);
    if (_recientes.isEmpty) return; // el temporizador borra las marcas
    _cuadro.value = _CuadroMulti(captura.imagen, [for (final v in _recientes.values) v.$1]);
    _limpiar?.cancel();
    _limpiar = Timer(const Duration(milliseconds: 400), () => _cuadro.value = null);
    if (_auto) _contarVisibles();
  }

  void _contarVisibles({bool manual = false}) {
    final cuadro = _cuadro.value;
    if (cuadro == null || cuadro.vistos.isEmpty) {
      // Disparador sin ningun codigo a la vista: aviso de error.
      if (manual) _sinCodigos();
      return;
    }
    final ahora = DateTime.now();
    var nuevos = 0;
    for (final v in cuadro.vistos) {
      if (!_contados.add(v.valor)) continue;
      widget.sesion.registrar(v.valor, v.formato, ahora, forzar: true);
      nuevos++;
    }
    // Repinta para que los recien contados pasen a verde.
    _cuadro.value = _CuadroMulti(cuadro.imagen, cuadro.vistos);
    if (nuevos == 0) return;
    // Un solo pitido por lote, aunque entren muchos codigos juntos.
    unawaited(AvisoLectura.leido(sonido: widget.ajustes.sonido, vibrar: widget.ajustes.vibrar));
    setState(() => _ultimoLote = nuevos);
    _ocultarLote?.cancel();
    _ocultarLote = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _ultimoLote = null);
    });
  }

  void _sinCodigos() {
    unawaited(AvisoLectura.fallo(sonido: widget.ajustes.sonido, vibrar: widget.ajustes.vibrar));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('No se ve ningun codigo. Acercate o apunta mejor.'),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          VistaCamara(camara: _camara),
          IgnorePointer(
            child: ValueListenableBuilder(
              valueListenable: _cuadro,
              builder: (context, cuadro, _) => CustomPaint(painter: _PuntosMulti(cuadro, _contados)),
            ),
          ),
          SafeArea(child: _encabezado()),
          if (_ultimoLote != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(24)),
                child: Text('+$_ultimoLote',
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
              ),
            ),
          Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(child: _barraInferior())),
        ],
      ),
    );
  }

  Widget _encabezado() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              const BackButton(color: Colors.white),
              const Expanded(
                child: Text('Conteo multiple',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const Text('Auto', style: TextStyle(color: Colors.white)),
              Switch(value: _auto, onChanged: (v) => setState(() => _auto = v)),
            ],
          ),
          ValueListenableBuilder(
            valueListenable: _cuadro,
            builder: (context, cuadro, _) {
              final vistos = cuadro?.vistos.length ?? 0;
              final listos = cuadro?.vistos.where((v) => _contados.contains(v.valor)).length ?? 0;
              return Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: vistos == 0 ? 0 : listos / vistos,
                      minHeight: 6,
                      backgroundColor: Colors.white24,
                      color: Colors.greenAccent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_contados.length} contados · $listos/$vistos a la vista',
                    style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _barraInferior() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ListenableBuilder(
            listenable: _camara,
            builder: (context, _) => BotonSobreCamara(
              icono: _camara.linterna ? Icons.flash_on : Icons.flash_off,
              tooltip: 'Linterna',
              onPressed: _camara.lista ? _camara.cambiarLinterna : null,
            ),
          ),
          Semantics(
            button: true,
            label: 'Contar todos los codigos a la vista',
            child: GestureDetector(
              onTap: () => _contarVisibles(manual: true),
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                padding: const EdgeInsets.all(5),
                child: const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white)),
              ),
            ),
          ),
          BotonSobreCamara(
            icono: Icons.check,
            tooltip: 'Terminar',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _CuadroMulti {
  _CuadroMulti(this.imagen, this.vistos);

  final Size imagen;
  final List<CodigoVisto> vistos;
}

/// Punto sobre cada codigo: blanco = por contar, verde con check = contado.
class _PuntosMulti extends CustomPainter {
  _PuntosMulti(this.cuadro, this.contados);

  final _CuadroMulti? cuadro;
  final Set<String> contados;

  @override
  void paint(Canvas canvas, Size size) {
    final c = cuadro;
    if (c == null) return;
    for (final v in c.vistos) {
      final puntos = proyectarACubrir(v.esquinas, c.imagen, size);
      if (puntos.length < 4) continue;
      final listo = contados.contains(v.valor);
      final color = listo ? Colors.greenAccent : Colors.white;
      canvas.drawPath(
        Path()..addPolygon(puntos, true),
        Paint()
          ..color = color.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final centro = centroDe(puntos);
      canvas.drawCircle(centro, 15, Paint()..color = listo ? Colors.green : Colors.white70);
      canvas.drawCircle(
        centro,
        15,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      if (listo) {
        final check = Path()
          ..moveTo(centro.dx - 6, centro.dy)
          ..lineTo(centro.dx - 1.5, centro.dy + 5)
          ..lineTo(centro.dx + 7, centro.dy - 5);
        canvas.drawPath(
          check,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  // Los contados cambian dentro del mismo Set: se repinta en cada cuadro.
  @override
  bool shouldRepaint(_PuntosMulti old) => true;
}
