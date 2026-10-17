import 'dart:ui';

import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/lectura/fusion.dart';
import 'package:flutter_test/flutter_test.dart';

CodigoVisto codigo(String valor, Simbologia s, String fuente, {String paso = 'rapido'}) =>
    CodigoVisto(valor, s.nombre, const [Offset(0, 0)], simbologia: s, fuente: fuente, detalle: paso);

void main() {
  test('un EAN se acepta al primer cuadro', () {
    final f = Fusion();
    expect(f.confirmar([codigo('7750182000123', Simbologia.ean13, 'C++')]).single.valor, '7750182000123');
  });

  test('ITF espera a verse igual en 2 cuadros', () {
    final f = Fusion();
    final itf = codigo('17750182000124', Simbologia.itf, 'C++');
    expect(f.confirmar([itf]), isEmpty);
    expect(f.confirmar([itf]).single.valor, '17750182000124');
  });

  test('una lectura parcial que no se repite nunca entra', () {
    final f = Fusion();
    expect(f.confirmar([codigo('177501', Simbologia.itf, 'C++')]), isEmpty);
    for (var i = 0; i < 3; i++) {
      f.confirmar([]);
    }
    expect(f.confirmar([codigo('177501', Simbologia.itf, 'C++')]), isEmpty);
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
      codigo('7750182000123', Simbologia.ean13, 'C++'), // repetido en el cuadro
    ]);
    expect(r.map((c) => c.valor), ['7750182000123', '7750182000124']);
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
}
