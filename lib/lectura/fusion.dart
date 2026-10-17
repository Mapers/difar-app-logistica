import 'dart:ui';

import '../core/codigos.dart';

/// Un codigo visto en un cuadro, con sus esquinas en la imagen ya puesta en
/// vertical (como se ve en pantalla).
class CodigoVisto {
  CodigoVisto(this.valor, this.formato, this.esquinas,
      {this.simbologia, this.fuente = '', this.detalle = '', this.verificado = false, this.rechazado = false});

  final String valor;
  final String formato;
  final List<Offset> esquinas;
  final Simbologia? simbologia;

  /// Que motor lo leyo (hoy siempre el propio, "C++").
  final String fuente;

  /// Paso del motor C++ que lo logro (para el registro).
  final String detalle;

  /// EAN/UPC con los digitos comprobados contra los tonos de gris de la imagen.
  final bool verificado;

  /// EAN/UPC cuyos digitos no calzaron con la imagen: no se cuenta (una
  /// lectura falsa sobre una imagen quieta se repite cuadro a cuadro); queda
  /// en el registro.
  final bool rechazado;
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
///   codigo). Lo leido sobre la imagen original entra al instante;
/// * lo leido en un recorte de OpenCV (enderezado y ampliado): en el
///   telefono (v0.11) salio 5750067000875 de la caja 7758467000875, 0,2 s
///   despues de leerla bien, y se conto como otro producto.
class Fusion {
  /// Pasos que leen la imagen original, sin prepararla (PasoMotor.nombre).
  static const _pasosDirectos = {'rapido', 'completo', 'invertido', ''};

  /// En el telefono, con el boton presionado, se analizan 7-10 cuadros/s y
  /// un mismo codigo a veces se lee 1 vez cada 1,5-2 s (registro v0.13).
  static const ventana = Duration(milliseconds: 3000);

  static const _eanUpc = {Simbologia.ean13, Simbologia.ean8, Simbologia.upcA, Simbologia.upcE};

  /// Se puede aceptar al primer cuadro: leido sobre la imagen original y con
  /// digito de control.
  /// EAN/UPC: al instante si el motor lo verifico contra la imagen; si los
  /// digitos no calzaron (en el telefono zxing leyo 4750412416093 de la caja
  /// 7750082416093), se pide repetido; si no se pudo saber, vale la regla de
  /// los demas (paso directo). En v0.14-v0.16 lo no verificado esperaba
  /// siempre y en el telefono las lecturas reales se perdian (registro v0.16).
  static bool esDirecto(CodigoVisto c) {
    if (_eanUpc.contains(c.simbologia)) {
      if (c.verificado) return true;
      if (c.rechazado) return false;
    }
    return _pasosDirectos.contains(c.detalle) && !(c.simbologia?.sinControl ?? false);
  }

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
        if (c.rechazado) return false;
        final dudoso = !codigos.any((o) => o.valor == c.valor && esDirecto(o));
        return !dudoso || (anterior != null && t.difference(anterior) <= ventana);
      }();
      (ok ? aceptados : dudosos).add(c);
    }
    retenidos = dudosos;
    if (_visto.length > 500) _visto.removeWhere((_, v) => t.difference(v) > ventana);
    return aceptados;
  }
}
