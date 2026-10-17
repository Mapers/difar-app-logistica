// Pruebas del enlace FFI con la biblioteca compilada para la PC:
//   cmake -S src -B /tmp/motor -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/motor
//   MOTOR_LECTOR_SO=/tmp/motor/libmotor_lector.so flutter test
// Sin MOTOR_LECTOR_SO se saltan (la app usa la de Android/iOS).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motor_lector/motor_lector.dart';

({int ancho, int alto, Uint8List px}) leerPgm(String nombre) {
  final d = File('test/escenas/$nombre.pgm').readAsBytesSync();
  final fin = d.indexOf(10); // "P5 W H 255\n"
  final partes = String.fromCharCodes(d.sublist(0, fin)).split(' ');
  return (ancho: int.parse(partes[1]), alto: int.parse(partes[2]), px: Uint8List.sublistView(d, fin + 1));
}

void main() {
  final so = Platform.environment['MOTOR_LECTOR_SO'];
  final saltar = so == null ? 'Falta MOTOR_LECTOR_SO (biblioteca del motor para la PC)' : null;

  ResultadoMotor leer(String escena, {int ronda = 0, int presupuestoUs = 0}) {
    final img = leerPgm(escena);
    return leerCuadro(img.px,
        ancho: img.ancho,
        alto: img.alto,
        bytesPorFila: img.ancho,
        presupuestoUs: presupuestoUs,
        ronda: ronda,
        biblioteca: so);
  }

  test('impresion invertida (1D): la lee el paso invertido', () {
    final r = leer('invertido_code128');
    expect(r.codigos.single.texto, 'LOTE-2026-A15');
    expect(r.codigos.single.formato, 'Code 128');
    expect(r.codigos.single.paso, PasoMotor.invertido);
    expect(r.codigos.single.invertido, isTrue);
  }, skip: saltar);

  test('bolsa con sombra y arrugas', () {
    final r = leer('bolsa_ean13');
    expect(r.codigos.single.texto, '7750182000123');
    expect(r.info.tiempoPorPaso, isNotEmpty);
  }, skip: saltar);

  test('codigo girado: esquinas sobre el codigo (centro de la imagen)', () {
    final r = leer('rotado_itf14');
    expect(r.codigos.single.texto, '17750182000124');
    final e = r.codigos.single.esquinas;
    final cx = e.map((p) => p.$1).reduce((a, b) => a + b) / 4;
    final cy = e.map((p) => p.$2).reduce((a, b) => a + b) / 4;
    expect(cx, closeTo(480, 60));
    expect(cy, closeTo(280, 60));
  }, skip: saltar);

  test('caso normal: paso rapido y datos del cuadro', () {
    final r = leer('normal_qr');
    expect(r.codigos.single.texto, 'DIFAR|PALLET|00042');
    expect(r.codigos.single.paso, PasoMotor.rapido);
    expect(r.info.brillo, inInclusiveRange(1, 255));
    expect(r.info.nitidez, greaterThan(0));
  }, skip: saltar);

  test('pasos repartidos entre cuadros con tope de tiempo', () {
    // Con 1 us de tope cada cuadro hace el rapido + un paso dificil y avanza la ronda.
    var ronda = 0;
    var leido = false;
    for (var i = 0; i < 8 && !leido; i++) {
      final r = leer('rotado_itf14', ronda: ronda, presupuestoUs: 1);
      expect(r.info.pasos, lessThanOrEqualTo(2));
      expect(r.info.siguienteRonda, greaterThan(ronda));
      ronda = r.info.siguienteRonda;
      leido = r.codigos.isNotEmpty;
    }
    expect(leido, isTrue);
  }, skip: saltar);

  test('imagen sin codigos: vacio, sin errores', () {
    final r = leerCuadro(Uint8List(320 * 240), ancho: 320, alto: 240, bytesPorFila: 320, biblioteca: so);
    expect(r.codigos, isEmpty);
    expect(r.info.sugerirLinterna, isTrue); // todo negro = poca luz
  }, skip: saltar);
}
