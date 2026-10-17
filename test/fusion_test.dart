import 'dart:ui';

import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/lectura/fusion.dart';
import 'package:flutter_test/flutter_test.dart';

CodigoVisto codigo(String valor, Simbologia s, String fuente) =>
    CodigoVisto(valor, s.nombre, const [Offset(0, 0)], simbologia: s, fuente: fuente);

void main() {
  test('un EAN de un solo motor se acepta al primer cuadro', () {
    final f = Fusion();
    expect(f.fusionar([codigo('7750182000123', Simbologia.ean13, 'C++')], []).single.fuente, 'C++');
  });

  test('ITF de un solo motor espera a verse en 2 cuadros', () {
    final f = Fusion();
    final itf = codigo('17750182000124', Simbologia.itf, 'C++');
    expect(f.fusionar([itf], []), isEmpty);
    expect(f.fusionar([itf], []).single.valor, '17750182000124');
  });

  test('ITF leido igual por los dos motores se acepta enseguida', () {
    final f = Fusion();
    final r = f.fusionar(
        [codigo('17750182000124', Simbologia.itf, 'C++')], [codigo('17750182000124', Simbologia.itf, 'ML Kit')]);
    expect(r.single.fuente, 'C++ + ML Kit');
  });

  test('una lectura parcial que no se repite nunca entra', () {
    final f = Fusion();
    expect(f.fusionar([codigo('177501', Simbologia.itf, 'C++')], []), isEmpty);
    for (var i = 0; i < 3; i++) {
      f.fusionar([], []);
    }
    expect(f.fusionar([codigo('177501', Simbologia.itf, 'C++')], []), isEmpty);
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
