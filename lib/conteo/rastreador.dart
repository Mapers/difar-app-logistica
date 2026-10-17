import 'dart:math' as math;
import 'dart:ui';

import '../core/proyeccion.dart';

/// Un codigo ubicado en un cuadro (leido o solo ubicado por OpenCV), con sus
/// esquinas en la imagen vertical.
class Observacion {
  Observacion(this.esquinas, {this.valor, this.formato, this.directa = false});

  final List<Offset> esquinas;
  final String? valor;
  final String? formato;

  /// Leido sobre la imagen original con un formato con digito de control:
  /// vale como dos votos (se acepta al primer cuadro).
  final bool directa;

  late final Offset centro = centroDe(esquinas);
  late final double largo = _largo(esquinas);
}

double _largo(List<Offset> e) {
  var m = 0.0;
  for (var i = 0; i < e.length; i++) {
    m = math.max(m, (e[i] - e[(i + 1) % e.length]).distance);
  }
  return m;
}

/// Una caja fisica seguida entre cuadros: mientras se mueve en la imagen es
/// la misma pista (mismo [id]), asi no se vuelve a contar ni a leer.
class Pista {
  Pista._(this.id, Observacion o, DateTime t, this.mundo)
      : esquinas = o.esquinas,
        centro = o.centro,
        largo = o.largo,
        primerVisto = t,
        ultimoVisto = t;

  final int id;
  List<Offset> esquinas;
  Offset centro;
  double largo;

  /// Posicion descontando el movimiento de la camara: si la caja sale de la
  /// imagen y vuelve, se reconoce por aca y no se cuenta dos veces.
  Offset mundo;
  final DateTime primerVisto;
  DateTime ultimoVisto;
  int vistas = 1;

  /// Valor aceptado (null = ubicado pero todavia sin leer).
  String? valor;
  String? formato;

  /// Cuando se acepto el valor (orden para "deshacer" y para saber que
  /// unidades sobran).
  DateTime? aceptada;

  /// Votacion entre cuadros: cada lectura suma; una lectura falsa suelta no
  /// gana a las buenas.
  final votos = <String, int>{};
  final _formatos = <String, String>{};

  /// Despues de un cambio de zoom las posiciones de antes ya no sirven.
  bool revivible = true;
}

class ResultadoRastreo {
  ResultadoRastreo(this.nuevas, this.cambiadas);

  /// Pistas que recien obtuvieron valor (unidades nuevas).
  final List<Pista> nuevas;

  /// Pistas cuyo valor cambio por votacion.
  final List<Pista> cambiadas;
}

/// Sigue los codigos de cuadro en cuadro: los asocia por valor y posicion,
/// estima cuanto se movio la camara y decide el valor de cada caja por
/// votacion entre cuadros.
class Rastreador {
  /// Una pista sin verse este tiempo deja de buscarse por posicion en la
  /// imagen (queda para reconocerla por [Pista.mundo]).
  static const activa = Duration(milliseconds: 700);

  /// Las ubicadas que nunca se leyeron se olvidan pasado este tiempo.
  static const olvido = Duration(seconds: 2);

  final pistas = <Pista>[];
  int _siguiente = 1;

  /// Movimiento acumulado de la imagen (pixeles).
  Offset _desplazamiento = Offset.zero;

  /// Ultimo movimiento de la imagen entre dos cuadros.
  Offset ultimoMovimiento = Offset.zero;

  Iterable<Pista> visibles(DateTime t, [Duration margen = const Duration(milliseconds: 300)]) =>
      pistas.where((p) => t.difference(p.ultimoVisto) <= margen);

  /// Despues de cambiar el zoom: lo que no se ve ya no se reconoce por posicion.
  void cambioDeEscala() {
    for (final p in pistas) {
      p.revivible = false;
    }
  }

  ResultadoRastreo actualizar(List<Observacion> obs, DateTime t) {
    final activas = [for (final p in pistas) if (t.difference(p.ultimoVisto) <= activa) p];
    final pares = <(Observacion, Pista)>[];
    final libresO = {...obs};
    final libresP = {...activas};

    // 1) Leidos contra pistas con el mismo valor (o que ya lo votaron).
    _emparejar(
      libresO.where((o) => o.valor != null).toList(),
      libresP.toList(),
      (o, p) => p.valor == o.valor || p.votos.containsKey(o.valor),
      (o, p) => math.max(2.0 * math.max(o.largo, p.largo), 150),
      Offset.zero,
      pares,
      libresO,
      libresP,
    );

    // Movimiento de la camara: la mediana de lo que se movieron esos pares.
    final g = pares.isEmpty ? Offset.zero : _mediana([for (final (o, p) in pares) o.centro - p.centro]);

    // 2) El resto por cercania a donde deberia estar cada pista.
    _emparejar(
      libresO.toList(),
      libresP.toList(),
      (o, p) => true,
      (o, p) => 0.9 * math.max(o.largo, p.largo) + 20,
      g,
      pares,
      libresO,
      libresP,
    );
    ultimoMovimiento = g;
    _desplazamiento += g;

    final nuevas = <Pista>[];
    final cambiadas = <Pista>[];
    void actualizarPista(Pista p, Observacion o) {
      p.esquinas = o.esquinas;
      p.centro = o.centro;
      p.largo = o.largo;
      p.mundo = o.centro - _desplazamiento;
      p.ultimoVisto = t;
      p.vistas++;
      p.revivible = true;
      _votar(p, o, t, nuevas, cambiadas);
    }

    for (final (o, p) in pares) {
      actualizarPista(p, o);
    }

    // 3) Lo que quedo: una caja que volvio a la imagen, o una nueva.
    for (final o in libresO) {
      final mundo = o.centro - _desplazamiento;
      Pista? vuelve;
      var mejor = double.infinity;
      for (final p in pistas) {
        if (!p.revivible || activas.contains(p) || p.ultimoVisto == t) continue;
        if (o.valor != null && p.valor != null && o.valor != p.valor) continue;
        final d = (p.mundo - mundo).distance;
        if (d < 0.8 * math.max(o.largo, p.largo) && d < mejor) {
          mejor = d;
          vuelve = p;
        }
      }
      if (vuelve != null) {
        actualizarPista(vuelve, o);
      } else {
        final p = Pista._(_siguiente++, o, t, mundo);
        pistas.add(p);
        _votar(p, o, t, nuevas, cambiadas, primera: true);
      }
    }

    pistas.removeWhere((p) => p.valor == null && t.difference(p.ultimoVisto) > olvido);
    return ResultadoRastreo(nuevas, cambiadas);
  }

  void _votar(Pista p, Observacion o, DateTime t, List<Pista> nuevas, List<Pista> cambiadas, {bool primera = false}) {
    final v = o.valor;
    if (v == null) return;
    p.votos[v] = (p.votos[v] ?? 0) + (o.directa ? 2 : 1);
    if (o.formato != null) p._formatos[v] = o.formato!;
    // Gana el mas votado con al menos 2 votos y mas que el segundo.
    String? primero;
    var a = 0, b = 0;
    p.votos.forEach((valor, n) {
      if (n > a) {
        b = a;
        a = n;
        primero = valor;
      } else if (n > b) {
        b = n;
      }
    });
    if (primero == null || a < 2 || a == b || primero == p.valor) return;
    final antes = p.valor;
    p.valor = primero;
    p.formato = p._formatos[primero];
    if (antes == null) {
      p.aceptada = t;
      nuevas.add(p);
    } else {
      cambiadas.add(p);
    }
  }

  static void _emparejar(
    List<Observacion> obs,
    List<Pista> ps,
    bool Function(Observacion, Pista) compatible,
    double Function(Observacion, Pista) radio,
    Offset movimiento,
    List<(Observacion, Pista)> pares,
    Set<Observacion> libresO,
    Set<Pista> libresP,
  ) {
    final candidatos = <(double, Observacion, Pista)>[];
    for (final o in obs) {
      for (final p in ps) {
        if (!compatible(o, p)) continue;
        final d = (o.centro - (p.centro + movimiento)).distance;
        if (d <= radio(o, p)) candidatos.add((d, o, p));
      }
    }
    candidatos.sort((x, y) => x.$1.compareTo(y.$1));
    for (final (_, o, p) in candidatos) {
      if (!libresO.contains(o) || !libresP.contains(p)) continue;
      libresO.remove(o);
      libresP.remove(p);
      pares.add((o, p));
    }
  }

  static Offset _mediana(List<Offset> v) {
    final xs = [for (final o in v) o.dx]..sort();
    final ys = [for (final o in v) o.dy]..sort();
    return Offset(xs[xs.length ~/ 2], ys[ys.length ~/ 2]);
  }
}
