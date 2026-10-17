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

/// Inverso de [aVertical]: de la imagen en vertical al sensor.
Offset desdeVertical(Offset p, Size sensor, int giro) => switch (giro % 360) {
      90 => Offset(p.dy, sensor.height - p.dx),
      180 => Offset(sensor.width - p.dx, sensor.height - p.dy),
      270 => Offset(sensor.width - p.dy, p.dx),
      _ => p,
    };

/// Filtra lecturas dudosas, que se aceptan solo si se vieron igual otra vez
/// en los ultimos [ventana] (un error no se repite igual; en el telefono los
/// falsos salieron todos distintos entre si, y los reales se repetian pero
/// no en cuadros seguidos porque los de en medio salian borrosos):
/// * formatos sin digito de control (ITF, Code 39/93, Codabar): un pedazo
///   del codigo tambien "decodifica";
/// * lo leido sobre imagen preparada (contraste, normalizacion, ampliacion,
///   giro): en el telefono salieron lecturas falsas que pasaban el digito
///   verificador del EAN-13 (1111130013606, 1551130053606... de un mismo
///   codigo). Lo leido sobre la imagen original entra al instante.
class Fusion {
  /// Pasos que leen la imagen original, sin prepararla (PasoMotor.nombre).
  static const _pasosDirectos = {'rapido', 'completo', 'invertido', 'detector', ''};

  static const ventana = Duration(milliseconds: 1500);

  final _visto = <String, DateTime>{};

  /// Los retenidos en el ultimo cuadro (para el registro).
  List<CodigoVisto> retenidos = const [];

  List<CodigoVisto> confirmar(List<CodigoVisto> codigos, [DateTime? ahora]) {
    final t = ahora ?? DateTime.now();
    final aceptados = <CodigoVisto>[];
    final dudosos = <CodigoVisto>[];
    // Se decide por valor y se devuelven todas sus instancias (cada caja
    // fisica es una lectura: dos cajas con el mismo EAN son dos).
    final decision = <String, bool>{};
    for (final c in codigos) {
      final ok = decision[c.valor] ??= () {
        final anterior = _visto[c.valor];
        _visto[c.valor] = t;
        final directo = codigos.any((o) => o.valor == c.valor && _pasosDirectos.contains(o.detalle));
        final dudoso = (c.simbologia?.sinControl ?? false) || !directo;
        return !dudoso || (anterior != null && t.difference(anterior) <= ventana);
      }();
      (ok ? aceptados : dudosos).add(c);
    }
    retenidos = dudosos;
    if (_visto.length > 500) _visto.removeWhere((_, v) => t.difference(v) > ventana);
    return aceptados;
  }
}
