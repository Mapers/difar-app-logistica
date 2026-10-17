import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/lectura/sesion_lectura.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 17, 10);

  group('SesionLectura', () {
    test('no cuenta dos veces el mismo codigo dentro de la espera', () {
      final s = SesionLectura(espera: const Duration(milliseconds: 1500));
      expect(s.registrar('7750001', 'EAN-13', t0), ResultadoLectura.nuevo);
      // La camara sigue viendo la etiqueta: cada cuadro renueva la espera.
      for (var ms = 100; ms <= 3000; ms += 100) {
        expect(s.registrar('7750001', 'EAN-13', t0.add(Duration(milliseconds: ms))),
            ResultadoLectura.ignorado);
      }
      expect(s.items.single.cantidad, 1);
    });

    test('suma cuando el codigo vuelve despues de la espera', () {
      final s = SesionLectura(espera: const Duration(milliseconds: 1500));
      s.registrar('A', 'Code 128', t0);
      s.registrar('B', 'Code 128', t0.add(const Duration(milliseconds: 200)));
      expect(s.registrar('A', 'Code 128', t0.add(const Duration(seconds: 2))), ResultadoLectura.sumado);
      expect(s.items.first.codigo, 'A');
      expect(s.items.first.cantidad, 2);
      expect(s.totalUnidades, 3);
    });

    test('sin sumar repetidos, el repetido se ignora', () {
      final s = SesionLectura(espera: Duration.zero);
      s.registrar('A', 'QR', t0);
      expect(s.registrar('A', 'QR', t0.add(const Duration(seconds: 5)), sumarRepetidos: false),
          ResultadoLectura.ignorado);
      expect(s.items.single.cantidad, 1);
    });

    test('forzar cuenta aunque se haya visto recien', () {
      final s = SesionLectura();
      s.registrar('A', 'QR', t0);
      expect(s.registrar('A', 'Manual', t0, forzar: true), ResultadoLectura.sumado);
      expect(s.items.single.cantidad, 2);
    });

    test('cantidad 0 elimina; vaciar borra todo; CSV', () {
      final s = SesionLectura();
      s.registrar('A', 'QR', t0);
      s.registrar('B', 'EAN-8', t0);
      s.cambiarCantidad('B', 5);
      expect(s.aCsv().split('\n')[2], startsWith('B;EAN-8;5;'));
      s.cambiarCantidad('A', 0);
      expect(s.items.map((e) => e.codigo), ['B']);
      s.vaciar();
      expect(s.items, isEmpty);
    });
  });

  test('digito verificador GS1', () {
    expect(digitoGs1Valido('7501031311309'), isTrue); // EAN-13
    expect(digitoGs1Valido('7501031311308'), isFalse);
    expect(digitoGs1Valido('96385074'), isTrue); // EAN-8
    expect(digitoGs1Valido('036000291452'), isTrue); // UPC-A
    expect(digitoGs1Valido('10012345678902'), isTrue); // GTIN-14
    expect(digitoGs1Valido('ABC'), isFalse);
  });
}
