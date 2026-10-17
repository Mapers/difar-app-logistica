import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/core/proyeccion.dart';
import 'package:difar_logistica/lectura/ajustes.dart';
import 'package:difar_logistica/lectura/pantalla_ajustes.dart';
import 'package:difar_logistica/lectura/pantalla_escaner.dart';
import 'package:difar_logistica/lectura/pantalla_lista.dart';
import 'package:difar_logistica/lectura/sesion_lectura.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('la lista muestra totales y suma/resta cantidades', (tester) async {
    final s = SesionLectura()..registrar('7501031311309', 'EAN-13', DateTime(2026));
    await tester.pumpWidget(MaterialApp(home: PantallaLista(sesion: s)));
    expect(find.text('1 codigos · 1 u.'), findsOneWidget);

    await tester.tap(find.byTooltip('Sumar'));
    await tester.pump();
    expect(find.text('1 codigos · 2 u.'), findsOneWidget);

    await tester.tap(find.byTooltip('Restar'));
    await tester.tap(find.byTooltip('Restar'));
    await tester.pump();
    expect(find.text('Todavia no hay codigos leidos.'), findsOneWidget);
  });

  testWidgets('ajustes guarda el grupo de formatos y el modo', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final a = Ajustes(await SharedPreferences.getInstance());
    expect(a.grupo, GrupoFormatos.logistica);

    await tester.pumpWidget(MaterialApp(home: PantallaAjustes(ajustes: a)));
    await tester.tap(find.text(GrupoFormatos.productos.etiqueta));
    await tester.tap(find.text('Multi'));
    await tester.pump();
    expect(a.grupo, GrupoFormatos.productos);
    expect(a.modo, ModoLectura.multi);
  });

  test('ventana de lectura: ancha para 1D, mas alta para 2D', () {
    const pantalla = Size(400, 800);
    final v1 = ventanaLectura(pantalla, GrupoFormatos.productos);
    final v2 = ventanaLectura(pantalla, GrupoFormatos.dosD);
    expect(v1.width, closeTo(344, 0.1));
    expect(v1.height, lessThan(v2.height));
    expect(const Offset(0, 0) & pantalla, isA<Rect>().having((r) => r.contains(v1.center), 'contiene', isTrue));
  });

  test('proyeccion a BoxFit.cover: imagen 720x1280 en vista 360x800', () {
    // escala = max(360/720, 800/1280) = 0.625 -> imagen 450x800, sobran 45 px por lado.
    final p = proyectarACubrir(const [Offset(360, 640), Offset(72, 0)], const Size(720, 1280), const Size(360, 800));
    expect(p[0], const Offset(180, 400));
    expect(p[1], const Offset(0, 0));
    expect(proyectarACubrir(const [Offset(1, 1)], Size.zero, const Size(1, 1)), isEmpty);
  });
}
