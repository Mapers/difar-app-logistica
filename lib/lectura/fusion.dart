import 'dart:ui';

import '../core/codigos.dart';

/// Un codigo visto en un cuadro, con sus esquinas en la imagen ya puesta en
/// vertical (como se ve en pantalla).
class CodigoVisto {
  CodigoVisto(this.valor, this.formato, this.esquinas, {this.simbologia, this.fuente = '', this.detalle = ''});

  final String valor;
  final String formato;
  final List<Offset> esquinas;
  final Simbologia? simbologia;

  /// Que motor lo leyo: "C++", "ML Kit" o "C++ + ML Kit".
  final String fuente;

  /// Paso del motor C++ que lo logro (para el registro).
  final String detalle;
}

/// Tamano de la imagen del sensor ya girada a vertical.
Size tamVertical(Size sensor, int giro) => giro % 180 == 0 ? sensor : Size(sensor.height, sensor.width);

/// Lleva un punto de la imagen del sensor a la imagen en vertical. [giro] es
/// la orientacion del sensor (90 en casi todas las camaras traseras).
Offset aVertical(Offset p, Size sensor, int giro) => switch (giro % 360) {
      90 => Offset(sensor.height - p.dy, p.dx),
      180 => Offset(sensor.width - p.dx, sensor.height - p.dy),
      270 => Offset(p.dy, sensor.width - p.dx),
      _ => p,
    };

/// Junta lo que leyeron los dos motores en un cuadro y filtra lecturas
/// dudosas: los formatos sin digito de control (ITF, Code 39/93, Codabar) se
/// aceptan si los leyeron ambos motores en el mismo cuadro o si se vieron
/// igual en uno de los 2 cuadros anteriores.
class Fusion {
  int _cuadro = 0;
  final _visto = <String, int>{};

  List<CodigoVisto> fusionar(List<CodigoVisto> cpp, List<CodigoVisto> mlkit) {
    _cuadro++;
    final porValor = <String, CodigoVisto>{};
    final enAmbos = <String>{};
    for (final c in cpp) {
      porValor.putIfAbsent(c.valor, () => c);
    }
    for (final c in mlkit) {
      final previo = porValor[c.valor];
      if (previo == null) {
        porValor[c.valor] = c;
      } else if (previo.fuente != c.fuente) {
        enAmbos.add(c.valor);
        porValor[c.valor] = CodigoVisto(previo.valor, previo.formato, previo.esquinas,
            simbologia: previo.simbologia ?? c.simbologia, fuente: 'C++ + ML Kit', detalle: previo.detalle);
      }
    }

    final aceptados = <CodigoVisto>[];
    for (final c in porValor.values) {
      final anterior = _visto[c.valor];
      _visto[c.valor] = _cuadro;
      final dudoso = c.simbologia?.sinControl ?? false;
      if (!dudoso || enAmbos.contains(c.valor) || (anterior != null && _cuadro - anterior <= 2)) {
        aceptados.add(c);
      }
    }
    if (_visto.length > 500) _visto.removeWhere((_, cuadro) => _cuadro - cuadro > 2);
    return aceptados;
  }
}
