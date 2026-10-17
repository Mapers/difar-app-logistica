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

  /// Que motor lo leyo (hoy siempre el propio, "C++").
  final String fuente;

  /// Paso del motor C++ que lo logro (para el registro).
  final String detalle;
}

/// Para el registro: largo del codigo en pixeles de la camara y, si se sabe
/// cuantos modulos tiene (EAN/UPC), pixeles por barra fina. Con menos de ~2
/// px por barra la lectura se vuelve dificil.
String tamanoCodigo(CodigoVisto c) {
  if (c.esquinas.length < 4) return '';
  var largo = 0.0;
  for (var i = 0; i < 4; i++) {
    final d = (c.esquinas[i] - c.esquinas[(i + 1) % 4]).distance;
    if (d > largo) largo = d;
  }
  final modulos = switch (c.simbologia) {
    Simbologia.ean13 || Simbologia.upcA => 95,
    Simbologia.ean8 => 67,
    Simbologia.upcE => 51,
    _ => 0,
  };
  return 'largo=${largo.round()}px${modulos > 0 ? ' (${(largo / modulos).toStringAsFixed(1)} px/barra)' : ''}';
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

/// Filtra lecturas dudosas: los formatos sin digito de control (ITF, Code
/// 39/93, Codabar) se aceptan solo si se vieron igual en uno de los 2 cuadros
/// anteriores (un pedazo de codigo no se repite igual).
class Fusion {
  int _cuadro = 0;
  final _visto = <String, int>{};

  List<CodigoVisto> confirmar(List<CodigoVisto> codigos) {
    _cuadro++;
    final aceptados = <CodigoVisto>[];
    final yaEnCuadro = <String>{};
    for (final c in codigos) {
      if (!yaEnCuadro.add(c.valor)) continue;
      final anterior = _visto[c.valor];
      _visto[c.valor] = _cuadro;
      final dudoso = c.simbologia?.sinControl ?? false;
      if (!dudoso || (anterior != null && _cuadro - anterior <= 2)) aceptados.add(c);
    }
    if (_visto.length > 500) _visto.removeWhere((_, cuadro) => _cuadro - cuadro > 2);
    return aceptados;
  }
}
