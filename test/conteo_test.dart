import 'package:difar_logistica/conteo/conteo.dart';
import 'package:difar_logistica/conteo/esperados.dart';
import 'package:difar_logistica/conteo/rastreador.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caja de 200x80 px con centro en (x, y).
Observacion caja(double x, double y, {String? valor, bool directa = true}) => Observacion(
      [Offset(x - 100, y - 40), Offset(x + 100, y - 40), Offset(x + 100, y + 40), Offset(x - 100, y + 40)],
      valor: valor,
      formato: valor == null ? null : 'EAN-13',
      directa: directa,
    );

final t0 = DateTime(2026, 10, 17, 10);
DateTime cuadro(int n) => t0.add(Duration(milliseconds: 50 * n));

void main() {
  test('dos cajas iguales en el mismo cuadro son dos unidades', () {
    final r = Rastreador();
    final res = r.actualizar([caja(200, 300, valor: '7753608815714'), caja(500, 300, valor: '7753608815714')], t0);
    expect(res.nuevas, hasLength(2));
    expect(r.pistas.map((p) => p.id).toSet(), hasLength(2));
  });

  test('moviendo la camara cada caja sigue siendo la misma (no se cuenta de nuevo)', () {
    final r = Rastreador();
    var unidades = 0;
    for (var n = 0; n < 15; n++) {
      final dx = -35.0 * n;
      unidades += r
          .actualizar([
            caja(300 + dx, 300, valor: 'A'),
            caja(600 + dx, 300, valor: 'A'),
            caja(900 + dx, 500), // ubicada por OpenCV, sin leer
          ], cuadro(n))
          .nuevas
          .length;
    }
    expect(unidades, 2);
    expect(r.pistas, hasLength(3));
  });

  test('una caja que sale de la imagen y vuelve no se cuenta dos veces', () {
    final r = Rastreador();
    var unidades = 0;
    var n = 0;
    // Se ve A, B y C; la camara va a la derecha hasta que A sale, y vuelve.
    for (final dx in [0, -100, -200, -300, -400, -400, -400, -400, -400, -400, -400, -400, -400, -400, -400, -400, -300,
      -200, -100, 0]) {
      final obs = [
        if (150 + dx > 0) caja(150.0 + dx, 300, valor: 'A'),
        caja(700.0 + dx, 300, valor: 'B'),
        caja(1000.0 + dx, 300, valor: 'C'),
      ];
      unidades += r.actualizar(obs, cuadro(n++)).nuevas.length;
    }
    expect(unidades, 3);
  });

  test('votacion: una lectura falsa suelta no cambia el valor de la caja', () {
    final r = Rastreador();
    r.actualizar([caja(300, 300, valor: '7758467000875', directa: false)], cuadro(0));
    expect(r.pistas.single.valor, isNull, reason: 'una lectura de recorte sola no alcanza');
    final res = r.actualizar([caja(305, 300, valor: '7758467000875', directa: false)], cuadro(1));
    expect(res.nuevas.single.valor, '7758467000875');
    r.actualizar([caja(310, 300, valor: '5750067000875', directa: false)], cuadro(2));
    r.actualizar([caja(312, 300, valor: '5750067000875', directa: false)], cuadro(3));
    expect(r.pistas.single.valor, '7758467000875', reason: 'empate: se queda el que ya tenia');
    expect(r.pistas, hasLength(1));
  });

  test('una zona ubicada sin leer pasa a leida en la misma pista', () {
    final r = Rastreador();
    r.actualizar([caja(300, 300)], cuadro(0));
    final id = r.pistas.single.id;
    final res = r.actualizar([caja(310, 302, valor: 'X')], cuadro(1));
    expect(res.nuevas.single.id, id);
  });

  test('conteo contra la lista: correcto, sobra, no esperado y deshacer', () {
    const lista = ListaEsperada('1', 'P', [Esperado('A', 'Prod A', 2), Esperado('B', 'Prod B', 1)]);
    final c = Conteo(lista: lista);
    c.actualizar([caja(100, 100, valor: 'A'), caja(400, 100, valor: 'A')], cuadro(0));
    c.actualizar([caja(100, 100, valor: 'A'), caja(400, 100, valor: 'A'), caja(700, 100, valor: 'A'),
      caja(100, 400, valor: 'Z')], cuadro(1));
    final estados = [for (final p in c.rastreador.pistas) c.estado(p)];
    expect(estados.where((e) => e == EstadoMarca.correcto), hasLength(2));
    expect(estados.where((e) => e == EstadoMarca.sobra), hasLength(1));
    expect(estados.where((e) => e == EstadoMarca.noEsperado), hasLength(1));
    expect(c.unidadesContadas, 4);
    expect(c.unidadesCubiertas, 2);
    expect(c.unidadesEsperadas, 3);
    final filas = {for (final f in c.resultados()) f.codigo: f};
    expect(filas['A']!.diferencia, 1);
    expect(filas['B']!.diferencia, -1);
    expect(filas['Z']!.contado, 1);
    expect(c.deshacer(), isNotNull);
    expect(c.unidadesContadas, 3);
    expect(c.aCsv(), contains('B,"Prod B",1,0,-1'));
  });
}
