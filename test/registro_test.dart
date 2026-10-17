import 'package:difar_logistica/core/registro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cada linea lleva fecha y hora, tipo y texto', () {
    Registro.instancia.memoria = [];
    registrar('LECTURA', '7750182000123 EAN-13 motor=C++');
    final linea = Registro.instancia.memoria!.single;
    expect(linea, matches(RegExp(r'^\d\d/\d\d \d\d:\d\d:\d\d\.\d{3} LECTURA 7750182000123 EAN-13 motor=C\+\+$')));
  });
}
