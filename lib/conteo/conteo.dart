import 'package:flutter/foundation.dart';

import 'esperados.dart';
import 'rastreador.dart';

/// Marca sobre cada caja, como MatrixScan Count.
enum EstadoMarca {
  /// Ubicada pero todavia sin leer (acercarse o esperar).
  porLeer,

  /// En la lista y dentro de la cantidad esperada.
  correcto,

  /// En la lista pero ya se conto todo lo esperado de ese producto.
  sobra,

  /// No esta en la lista.
  noEsperado,

  /// Contada (conteo sin lista).
  contado,
}

class FilaResultado {
  FilaResultado(this.codigo, this.descripcion, this.esperado, this.contado);

  final String codigo;
  final String descripcion;
  final int esperado;
  final int contado;

  int get diferencia => contado - esperado;
}

/// Un conteo: las cajas seguidas por el [Rastreador] contra la lista esperada.
/// Cada caja fisica es una unidad (10 cajas iguales = 10).
class Conteo extends ChangeNotifier {
  Conteo({this.lista});

  final ListaEsperada? lista;
  Rastreador rastreador = Rastreador();

  /// Unidades que el operario saco del conteo (deshacer, o tocar la marca).
  final excluidas = <int>{};

  Iterable<Pista> get contadas => rastreador.pistas.where((p) => p.valor != null && !excluidas.contains(p.id));

  int get unidadesContadas => contadas.length;
  int get unidadesEsperadas => lista?.unidades ?? 0;

  /// Unidades de la lista ya cubiertas (sin contar las que sobran).
  int get unidadesCubiertas {
    final l = lista;
    if (l == null) return unidadesContadas;
    final c = porCodigo();
    return l.items.fold(0, (s, e) => s + (c[e.codigo] ?? 0).clamp(0, e.cantidad));
  }

  Map<String, int> porCodigo() {
    final m = <String, int>{};
    for (final p in contadas) {
      m[p.valor!] = (m[p.valor!] ?? 0) + 1;
    }
    return m;
  }

  ResultadoRastreo actualizar(List<Observacion> obs, DateTime t) {
    final r = rastreador.actualizar(obs, t);
    if (r.nuevas.isNotEmpty || r.cambiadas.isNotEmpty) notifyListeners();
    return r;
  }

  EstadoMarca estado(Pista p) {
    final v = p.valor;
    if (v == null) return EstadoMarca.porLeer;
    final l = lista;
    if (l == null) return EstadoMarca.contado;
    final esperado = l.cantidad(v);
    if (esperado == 0) return EstadoMarca.noEsperado;
    // Las primeras [esperado] unidades (en el orden en que se contaron) estan
    // bien; las siguientes sobran.
    final iguales = contadas.where((o) => o.valor == v).toList()
      ..sort((a, b) => a.aceptada!.compareTo(b.aceptada!));
    final i = iguales.indexOf(p);
    if (i < 0) return EstadoMarca.correcto; // excluida: se dibuja aparte
    return i < esperado ? EstadoMarca.correcto : EstadoMarca.sobra;
  }

  /// Saca la ultima unidad contada. Devuelve su valor, o null si no hay.
  String? deshacer() {
    final lista = contadas.toList()..sort((a, b) => a.aceptada!.compareTo(b.aceptada!));
    if (lista.isEmpty) return null;
    excluidas.add(lista.last.id);
    notifyListeners();
    return lista.last.valor;
  }

  void alternarExclusion(Pista p) {
    if (!excluidas.remove(p.id)) excluidas.add(p.id);
    notifyListeners();
  }

  void reiniciar() {
    rastreador = Rastreador();
    excluidas.clear();
    notifyListeners();
  }

  /// Contado / falta / sobra por producto (los de la lista primero).
  List<FilaResultado> resultados() {
    final c = porCodigo();
    final filas = <FilaResultado>[];
    for (final e in lista?.items ?? const <Esperado>[]) {
      filas.add(FilaResultado(e.codigo, e.descripcion, e.cantidad, c.remove(e.codigo) ?? 0));
    }
    for (final e in c.entries) {
      filas.add(FilaResultado(e.key, lista == null ? '' : 'No esta en la lista', 0, e.value));
    }
    return filas;
  }

  String aCsv() {
    final b = StringBuffer('codigo,descripcion,esperado,contado,diferencia\n');
    for (final f in resultados()) {
      b.writeln('${f.codigo},"${f.descripcion.replaceAll('"', '""')}",${f.esperado},${f.contado},${f.diferencia}');
    }
    return b.toString();
  }
}
