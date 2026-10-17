import 'package:difar_logistica/conteo/pantalla_conteo.dart';
import 'package:difar_logistica/lectura/ajustes.dart';
import 'package:difar_logistica/lectura/sesion_lectura.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('conteo: elegir la lista simulada muestra el progreso 0/8', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final a = Ajustes(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(home: PantallaConteo(sesion: SesionLectura(), ajustes: a)));
    await tester.pumpAndSettle();
    expect(find.text('Pedido 1001 (simulado)'), findsOneWidget);
    await tester.tap(find.text('Pedido 1001 (simulado)'));
    await tester.pumpAndSettle();
    expect(find.text('0/8'), findsOneWidget);
    await tester.tap(find.textContaining('Ver ('));
    await tester.pumpAndSettle();
    expect(find.text('Falta'), findsOneWidget);
  });

  testWidgets('escanear varios: empieza directo, sin elegir lista', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final a = Ajustes(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(home: PantallaConteo(sesion: SesionLectura(), ajustes: a, sinLista: true)));
    await tester.pumpAndSettle();
    expect(find.text('Pedido 1001 (simulado)'), findsNothing);
    expect(find.text('Escanear varios'), findsOneWidget);
    expect(find.textContaining('Ver ('), findsOneWidget);
    // El registro escribe en lotes con un temporizador: se deja terminar.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
