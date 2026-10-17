import 'package:difar_logistica/lectura/aviso_lectura.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const canal = MethodChannel('difar/pitido');
  final llamadas = <MethodCall>[];

  setUp(() {
    llamadas.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (c) async {
      llamadas.add(c);
      return null;
    });
  });

  test('lectura correcta: vibracion corta y pitido', () async {
    await AvisoLectura.leido(sonido: true, vibrar: true);
    expect(llamadas.map((c) => c.method), ['vibrar', 'pitido']);
    expect((llamadas.first.arguments as Map)['patron'], [0, 70]);
  });

  test('fallo: sonido de error distinto y doble vibracion', () async {
    await AvisoLectura.fallo(sonido: true, vibrar: true);
    expect(llamadas.map((c) => c.method), ['vibrar', 'error']);
    expect((llamadas.first.arguments as Map)['patron'], [0, 180, 100, 180]);
  });

  test('respeta los ajustes de sonido y vibracion', () async {
    await AvisoLectura.fallo(sonido: false, vibrar: false);
    expect(llamadas, isEmpty);
  });
}
