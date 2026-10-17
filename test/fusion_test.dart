import 'dart:ui';

import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/lectura/fusion.dart';
import 'package:flutter_test/flutter_test.dart';

/// Por defecto lo leido por el paso rapido llega verificado por el motor.
CodigoVisto codigo(String valor, Simbologia s, String fuente, {String paso = 'rapido', bool? verificado}) =>
    CodigoVisto(valor, s.nombre, const [Offset(0, 0)],
        simbologia: s, fuente: fuente, detalle: paso, verificado: verificado ?? paso == 'rapido');

void main() {
  test('un EAN se acepta al primer cuadro', () {
    final f = Fusion();
    expect(f.confirmar([codigo('7750182000123', Simbologia.ean13, 'C++')]).single.valor, '7750182000123');
  });

  test('un real que se repite con cuadros borrosos en medio (dentro de 3 s) entra', () {
    final f = Fusion();
    final t0 = DateTime(2026, 10, 16, 22, 47);
    final c = codigo('2050000610684', Simbologia.ean13, 'C++', paso: 'detector+contraste');
    expect(f.confirmar([c], t0), isEmpty);
    expect(f.confirmar([], t0.add(const Duration(milliseconds: 300))), isEmpty);
    expect(f.confirmar([c], t0.add(const Duration(milliseconds: 900))).single.valor, '2050000610684');
    // Si vuelve despues de la ventana, empieza de nuevo.
    final g = Fusion();
    expect(g.confirmar([c], t0), isEmpty);
    expect(g.confirmar([c], t0.add(const Duration(seconds: 4))), isEmpty);
  });

  test('ITF espera a verse igual en 2 cuadros', () {
    final f = Fusion();
    final itf = codigo('17750182000124', Simbologia.itf, 'C++');
    expect(f.confirmar([itf]), isEmpty);
    expect(f.confirmar([itf]).single.valor, '17750182000124');
  });

  test('una lectura parcial que no se repite nunca entra', () {
    final f = Fusion();
    final t0 = DateTime(2026, 10, 16);
    expect(f.confirmar([codigo('177501', Simbologia.itf, 'C++')], t0), isEmpty);
    expect(f.confirmar([codigo('177501', Simbologia.itf, 'C++')], t0.add(const Duration(seconds: 4))), isEmpty);
  });

  test('EAN leido sobre imagen preparada espera a repetirse; una lectura falsa suelta no entra', () {
    final f = Fusion();
    expect(f.confirmar([codigo('1551130053606', Simbologia.ean13, 'C++', paso: 'ampliado')]), isEmpty);
    expect(f.confirmar([codigo('1111130013606', Simbologia.ean13, 'C++', paso: 'reflejos/sombras')]), isEmpty);
    // El real se repite en el cuadro siguiente: entra.
    expect(f.confirmar([codigo('1551130053606', Simbologia.ean13, 'C++', paso: 'poca luz')]).single.valor,
        '1551130053606');
  });

  test('varios codigos del mismo cuadro salen juntos', () {
    final f = Fusion();
    final r = f.confirmar([
      codigo('7750182000123', Simbologia.ean13, 'C++'),
      codigo('7750182000124', Simbologia.ean13, 'C++'),
      codigo('7750182000123', Simbologia.ean13, 'C++'), // otra caja con el mismo EAN
    ]);
    // Cada caja fisica es una lectura: dos cajas iguales salen las dos.
    expect(r.map((c) => c.valor), ['7750182000123', '7750182000124', '7750182000123']);
  });

  test('sensor girado 90: punto de la imagen horizontal a la vertical', () {
    const sensor = Size(1280, 720);
    expect(tamVertical(sensor, 90), const Size(720, 1280));
    // Arriba a la izquierda del sensor queda arriba a la derecha en vertical.
    expect(aVertical(const Offset(0, 0), sensor, 90), const Offset(720, 0));
    expect(aVertical(const Offset(1280, 720), sensor, 90), const Offset(0, 1280));
    expect(aVertical(const Offset(10, 20), sensor, 270), const Offset(20, 1270));
  });

  test('tamano del codigo para el registro', () {
    final c = CodigoVisto('7750182000123', 'EAN-13', const [Offset(0, 0), Offset(190, 0), Offset(190, 60), Offset(0, 60)],
        simbologia: Simbologia.ean13);
    expect(tamanoCodigo(c), 'largo=190px (2.0 px/barra)');
  });

  test('Code 128 tambien se confirma en 2 cuadros', () {
    final f = Fusion();
    expect(f.confirmar([codigo(r'$1PJN7B$0', Simbologia.code128, 'C++')]), isEmpty);
  });

  test('lo leido en un recorte de OpenCV espera a repetirse (lectura falsa del telefono v0.11)', () {
    final f = Fusion();
    final t0 = DateTime(2026, 10, 16, 23, 29, 4);
    final real = codigo('7758467000875', Simbologia.ean13, 'C++', paso: 'detector');
    final falso = codigo('5750067000875', Simbologia.ean13, 'C++', paso: 'detector');
    expect(f.confirmar([real], t0), isEmpty);
    expect(f.confirmar([real], t0.add(const Duration(milliseconds: 60))).single.valor, '7758467000875');
    expect(f.confirmar([falso], t0.add(const Duration(milliseconds: 190))), isEmpty);
    expect(f.confirmar([real], t0.add(const Duration(milliseconds: 250))).single.valor, '7758467000875');
  });

  test('desdeVertical deshace aVertical (tocar para enfocar)', () {
    const sensor = Size(1920, 1080);
    for (final giro in [0, 90, 180, 270]) {
      const p = Offset(300, 200);
      expect(desdeVertical(aVertical(p, sensor, giro), sensor, giro), p, reason: 'giro $giro');
    }
  });

  test('EAN sin verificar contra la imagen espera a repetirse aunque venga del paso rapido (falso del telefono v0.13)', () {
    final f = Fusion();
    final t0 = DateTime(2026, 10, 17, 6, 26, 15);
    expect(f.confirmar([codigo('4750412416093', Simbologia.ean13, 'C++', verificado: false)], t0), isEmpty);
    expect(f.confirmar([codigo('7750082416093', Simbologia.ean13, 'C++')], t0).single.valor, '7750082416093');
  });
}
