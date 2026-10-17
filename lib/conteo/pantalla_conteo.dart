import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../core/proyeccion.dart';
import '../core/registro.dart';
import '../lectura/ajustes.dart';
import '../lectura/aviso_lectura.dart';
import '../lectura/camara_comun.dart';
import '../lectura/camara_lectora.dart';
import '../lectura/fusion.dart';
import '../lectura/sesion_lectura.dart';
import 'conteo.dart';
import 'esperados.dart';
import 'rastreador.dart';

/// Conteo como MatrixScan Count: camara a pantalla completa, cada caja se
/// sigue en vivo con su marca (verde = esperado, rojo = sobra o no esta en
/// la lista, amarillo = ubicado sin leer) y se cuenta una sola vez aunque se
/// mueva el telefono. Progreso contra la lista esperada.
class PantallaConteo extends StatefulWidget {
  const PantallaConteo({
    super.key,
    required this.sesion,
    required this.ajustes,
    this.fuente = const FuenteSimulada(),
  });

  final SesionLectura sesion;
  final Ajustes ajustes;
  final FuenteEsperados fuente;

  @override
  State<PantallaConteo> createState() => _PantallaConteoState();
}

class _PantallaConteoState extends State<PantallaConteo> {
  late final CamaraLectora _camara = CamaraLectora(widget.ajustes, multiple: true);
  StreamSubscription<Captura>? _capturas;
  Conteo? _conteo;
  bool _eligiendo = true;

  /// Ya se aviso que la lista esta completa (vuelve a avisar si se deshace).
  bool _completa = false;

  /// Se repinta en cada cuadro (marcas en vivo).
  final _tic = ValueNotifier<int>(0);
  Size _imagen = Size.zero;
  double _aumento = 1;

  /// Centro de cada marca dibujada (para tocarla).
  final _marcas = <int, Offset>{};
  DateTime _ultimoPitido = DateTime(2000), _ultimoError = DateTime(2000);

  @override
  void initState() {
    super.initState();
    _camara.esfuerzo = true; // todos los pasos del motor, siempre
    _capturas = _camara.capturas.listen(_alCapturar);
    _camara.addListener(_alCambiarCamara);
    unawaited(_camara.iniciar());
    WidgetsBinding.instance.addPostFrameCallback((_) => _elegirLista());
  }

  @override
  void dispose() {
    unawaited(_capturas?.cancel());
    _camara.removeListener(_alCambiarCamara);
    _camara.dispose();
    _conteo?.dispose();
    _tic.dispose();
    super.dispose();
  }

  void _alCambiarCamara() {
    if (_camara.aumento != _aumento) {
      _aumento = _camara.aumento;
      _conteo?.rastreador.cambioDeEscala();
    }
  }

  Future<void> _elegirLista() async {
    final listas = await widget.fuente.listas();
    if (!mounted) return;
    final elegida = await showModalBottomSheet<Object>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Que se va a contar', style: TextStyle(fontWeight: FontWeight.w600))),
            for (final l in listas)
              ListTile(
                leading: const Icon(Icons.assignment_outlined),
                title: Text(l.nombre),
                subtitle: Text('${l.items.length} productos · ${l.unidades} unidades'),
                onTap: () => Navigator.pop(context, l),
              ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('Sin lista (contar todo)'),
              onTap: () => Navigator.pop(context, 'libre'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancelar'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (elegida == null) {
      Navigator.of(context).pop();
      return;
    }
    final lista = elegida is ListaEsperada ? elegida : null;
    registrar('CONTEO', 'inicio ${lista == null ? "sin lista" : "${lista.nombre}: ${lista.unidades} unidades"}');
    setState(() {
      _conteo = Conteo(lista: lista)..addListener(_alCambiarConteo);
      _eligiendo = false;
    });
  }

  void _alCambiarConteo() {
    final c = _conteo;
    if (c != null) _revisarCompleta(c);
    if (mounted) setState(() {});
  }

  void _alCapturar(Captura c) {
    final conteo = _conteo;
    if (conteo == null) return;
    final ahora = DateTime.now();
    _imagen = c.imagen;
    final obs = [
      // Lo que no calza con la imagen cuenta como ubicado sin leer.
      for (final v in c.crudos)
        v.rechazado
            ? Observacion(v.esquinas)
            : Observacion(v.esquinas, valor: v.valor, formato: v.formato, directa: Fusion.esDirecto(v)),
      for (final q in c.sinLeer) Observacion(q),
    ];
    final r = conteo.actualizar(obs, ahora);
    for (final p in r.nuevas) {
      final estado = conteo.estado(p);
      registrar('CONTEO', '+1 ${p.valor} ${p.formato ?? ''} ${estado.name} caja=${p.id} '
          'leida_en=${p.aceptada!.difference(p.primerVisto).inMilliseconds}ms votos=${p.votos} '
          'total=${conteo.unidadesContadas}${conteo.lista == null ? '' : '/${conteo.unidadesEsperadas}'}');
      _avisar(estado);
    }
    for (final p in r.cambiadas) {
      registrar('CONTEO', 'caja=${p.id} corregida por votacion a ${p.valor} votos=${p.votos}');
    }
    _revisarCompleta(conteo);
    _tic.value++;
  }

  void _avisar(EstadoMarca e) {
    final ahora = DateTime.now();
    final malo = e == EstadoMarca.sobra || e == EstadoMarca.noEsperado;
    if (malo) {
      if (ahora.difference(_ultimoError) < const Duration(milliseconds: 600)) return;
      _ultimoError = ahora;
      unawaited(AvisoLectura.fallo(sonido: widget.ajustes.sonido, vibrar: widget.ajustes.vibrar));
    } else {
      // Muchas cajas a la vez: un pitido cada tanto, no uno encima del otro.
      if (ahora.difference(_ultimoPitido) < const Duration(milliseconds: 120)) return;
      _ultimoPitido = ahora;
      unawaited(AvisoLectura.leido(sonido: widget.ajustes.sonido, vibrar: widget.ajustes.vibrar));
    }
  }

  // ------------------------------------------------------------ acciones

  void _tocar(Offset punto, Size vista) {
    int? cerca;
    var mejor = 32.0;
    _marcas.forEach((id, c) {
      final d = (c - punto).distance;
      if (d < mejor) {
        mejor = d;
        cerca = id;
      }
    });
    final conteo = _conteo;
    if (cerca == null || conteo == null) {
      unawaited(_camara.enfocar(punto, vista));
      return;
    }
    final p = conteo.rastreador.pistas.where((p) => p.id == cerca).firstOrNull;
    if (p != null) unawaited(_detalle(conteo, p));
  }

  Future<void> _detalle(Conteo conteo, Pista p) async {
    final excluida = conteo.excluidas.contains(p.id);
    final valor = p.valor;
    final e = valor == null ? null : conteo.lista?.buscar(valor);
    final contadoProducto = valor == null ? 0 : conteo.porCodigo()[valor] ?? 0;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(valor ?? 'Sin leer', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              if (valor == null)
                const Text('Se ve un codigo pero todavia no se pudo leer. Acercate o espera un momento.')
              else ...[
                Text('${p.formato ?? ''} · caja ${p.id}'),
                if (conteo.lista != null)
                  Text(e == null
                      ? 'No esta en la lista'
                      : '${e.descripcion}: contadas $contadoProducto de ${e.cantidad}'),
                Text('Lecturas: ${p.votos.entries.map((v) => '${v.key} (${v.value})').join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () {
                    conteo.alternarExclusion(p);
                    registrar('CONTEO', '${excluida ? "vuelve a contar" : "no contar"} caja=${p.id} $valor');
                    Navigator.pop(context);
                  },
                  child: Text(excluida ? 'Volver a contar esta unidad' : 'No contar esta unidad'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Lista completa (todo lo esperado contado, nada de mas): se avisa una vez
  /// con un sonido y un cartel, y se ofrece terminar.
  void _revisarCompleta(Conteo conteo) {
    final l = conteo.lista;
    if (l == null) return;
    final completa = conteo.unidadesEsperadas > 0 &&
        conteo.unidadesCubiertas == conteo.unidadesEsperadas &&
        conteo.unidadesContadas == conteo.unidadesEsperadas;
    if (completa == _completa) return;
    _completa = completa;
    if (!completa || !mounted) return;
    registrar('CONTEO', 'lista completa ${l.nombre}: ${conteo.unidadesEsperadas} unidades');
    unawaited(AvisoLectura.leido(sonido: widget.ajustes.sonido, vibrar: widget.ajustes.vibrar));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Lista completa: ${conteo.unidadesEsperadas} de ${conteo.unidadesEsperadas}'),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Terminar', textColor: Colors.white, onPressed: () => _resultados(terminar: true)),
      ));
  }

  void _deshacer() {
    final v = _conteo?.deshacer();
    if (v == null) return;
    registrar('CONTEO', 'deshacer $v');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Se quito 1 unidad de $v'), duration: const Duration(seconds: 2)));
  }

  Future<void> _reiniciar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empezar de nuevo'),
        content: const Text('Se borra lo contado en este conteo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok == true) {
      registrar('CONTEO', 'reinicio');
      _conteo?.reiniciar();
    }
  }

  Future<void> _compartir(Conteo conteo) async {
    final nombre = 'conteo_${conteo.lista?.id ?? 'libre'}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(utf8.encode(conteo.aCsv()), mimeType: 'text/csv', name: nombre)],
      fileNameOverrides: [nombre],
      subject: 'Conteo DIFAR ${conteo.lista?.nombre ?? ''}',
    ));
  }

  Future<void> _resultados({bool terminar = false}) async {
    final conteo = _conteo;
    if (conteo == null) return;
    final salir = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _Resultados(conteo: conteo, terminar: terminar, compartir: () => _compartir(conteo)),
    );
    if (salir == null || !mounted) return;
    if (salir) {
      // Agregar a la lista principal: cada unidad contada suma 1.
      final ahora = DateTime.now();
      for (final f in conteo.resultados()) {
        for (var i = 0; i < f.contado; i++) {
          widget.sesion.registrar(f.codigo, '', ahora, forzar: true);
        }
      }
    }
    registrar('CONTEO', 'fin ${conteo.unidadesContadas} unidades${salir ? " (agregadas a la lista)" : ""}: '
        '${conteo.resultados().map((f) => '${f.codigo}=${f.contado}/${f.esperado}').join(' ')}');
    if (mounted) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ vista

  @override
  Widget build(BuildContext context) {
    final conteo = _conteo;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          VistaCamara(camara: _camara),
          if (conteo != null)
            LayoutBuilder(
              builder: (context, c) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (t) => _tocar(t.localPosition, c.biggest),
                child: ValueListenableBuilder(
                  valueListenable: _tic,
                  builder: (context, _, _) => CustomPaint(
                    size: c.biggest,
                    painter: _Marcas(conteo, _imagen, DateTime.now(), _marcas),
                  ),
                ),
              ),
            ),
          SafeArea(child: _encabezado(conteo)),
          if (!_eligiendo && conteo != null)
            Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(child: _barraInferior(conteo))),
        ],
      ),
    );
  }

  Widget _encabezado(Conteo? conteo) {
    final lista = conteo?.lista;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              const BackButton(color: Colors.white),
              Expanded(
                child: Text(lista?.nombre ?? 'Conteo',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              if (conteo != null)
                Text(
                  lista == null
                      ? '${conteo.unidadesContadas}'
                      : '${conteo.unidadesCubiertas}/${conteo.unidadesEsperadas}',
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
            ],
          ),
          if (conteo != null && lista != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: conteo.unidadesEsperadas == 0 ? 0 : conteo.unidadesCubiertas / conteo.unidadesEsperadas,
                minHeight: 6,
                backgroundColor: Colors.white24,
                color: Colors.greenAccent,
              ),
            ),
          if (conteo != null)
            ValueListenableBuilder(
              valueListenable: _tic,
              builder: (context, _, _) {
                final visibles = conteo.rastreador.visibles(DateTime.now()).toList();
                int cuantos(bool Function(EstadoMarca) f) => visibles.where((p) => f(conteo.estado(p))).length;
                final ok = cuantos((e) => e == EstadoMarca.correcto || e == EstadoMarca.contado);
                final mal = cuantos((e) => e == EstadoMarca.sobra || e == EstadoMarca.noEsperado);
                final sin = cuantos((e) => e == EstadoMarca.porLeer);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('A la vista: ✅ $ok   ❌ $mal   ⚠️ $sin',
                      style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _barraInferior(Conteo conteo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
          BotonSobreCamara(icono: Icons.undo, tooltip: 'Quitar la ultima unidad', onPressed: _deshacer),
          FilledButton.icon(
            onPressed: () => _resultados(),
            icon: const Icon(Icons.list_alt),
            label: Text('Ver (${conteo.unidadesContadas})'),
          ),
          BotonSobreCamara(icono: Icons.restart_alt, tooltip: 'Empezar de nuevo', onPressed: _reiniciar),
          BotonSobreCamara(icono: Icons.check, tooltip: 'Terminar', onPressed: () => _resultados(terminar: true)),
        ],
      ),
    );
  }
}

/// Contado / Falta / Sobra, compartir CSV y terminar.
class _Resultados extends StatelessWidget {
  const _Resultados({required this.conteo, required this.terminar, required this.compartir});

  final Conteo conteo;
  final bool terminar;
  final VoidCallback compartir;

  @override
  Widget build(BuildContext context) {
    final filas = conteo.resultados();
    Widget tabla(List<FilaResultado> f, String vacio) => f.isEmpty
        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(vacio)))
        : ListView(
            children: [
              for (final x in f)
                ListTile(
                  dense: true,
                  title: Text(x.codigo),
                  subtitle: x.descripcion.isEmpty ? null : Text(x.descripcion),
                  trailing: Text(
                    conteo.lista == null ? '${x.contado}' : '${x.contado} / ${x.esperado}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: x.diferencia == 0 || conteo.lista == null
                          ? Colors.green
                          : x.diferencia < 0
                              ? Colors.orange
                              : Colors.red,
                    ),
                  ),
                ),
            ],
          );
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              const TabBar(tabs: [Tab(text: 'Contado'), Tab(text: 'Falta'), Tab(text: 'Sobra')]),
              Expanded(
                child: TabBarView(children: [
                  tabla(filas.where((f) => f.contado > 0).toList(), 'Todavia no se conto nada'),
                  tabla(filas.where((f) => f.diferencia < 0).toList(), 'No falta nada'),
                  tabla(filas.where((f) => f.diferencia > 0).toList(), 'No sobra nada'),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(onPressed: compartir, icon: const Icon(Icons.share), label: const Text('CSV')),
                    if (terminar) ...[
                      OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Salir sin agregar')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Agregar a la lista')),
                    ] else
                      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Seguir contando')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Marca sobre cada caja a la vista.
class _Marcas extends CustomPainter {
  _Marcas(this.conteo, this.imagen, this.ahora, this.centros);

  final Conteo conteo;
  final Size imagen;
  final DateTime ahora;
  final Map<int, Offset> centros;

  @override
  void paint(Canvas canvas, Size size) {
    centros.clear();
    if (imagen.isEmpty) return;
    for (final p in conteo.rastreador.visibles(ahora)) {
      final puntos = proyectarACubrir(p.esquinas, imagen, size);
      if (puntos.length < 4) continue;
      final c = centroDe(puntos);
      centros[p.id] = c;
      final excluida = conteo.excluidas.contains(p.id);
      final estado = conteo.estado(p);
      final color = excluida
          ? Colors.grey
          : switch (estado) {
              EstadoMarca.correcto => Colors.green,
              EstadoMarca.contado => Colors.blue,
              EstadoMarca.sobra || EstadoMarca.noEsperado => Colors.red,
              EstadoMarca.porLeer => Colors.amber,
            };
      canvas.drawPath(
        Path()..addPolygon(puntos, true),
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(c, 16, Paint()..color = color);
      canvas.drawCircle(
        c,
        16,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      final trazo = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      if (excluida) {
        canvas.drawLine(c.translate(-7, 0), c.translate(7, 0), trazo);
      } else {
        switch (estado) {
          case EstadoMarca.correcto || EstadoMarca.contado:
            canvas.drawPath(
                Path()
                  ..moveTo(c.dx - 7, c.dy)
                  ..lineTo(c.dx - 2, c.dy + 5)
                  ..lineTo(c.dx + 7, c.dy - 5),
                trazo);
          case EstadoMarca.sobra || EstadoMarca.noEsperado:
            canvas.drawLine(c.translate(-6, -6), c.translate(6, 6), trazo);
            canvas.drawLine(c.translate(6, -6), c.translate(-6, 6), trazo);
          case EstadoMarca.porLeer:
            canvas.drawLine(c.translate(0, -7), c.translate(0, 2), trazo);
            canvas.drawCircle(c.translate(0, 7), 1.8, Paint()..color = Colors.white);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Marcas old) => true;
}
