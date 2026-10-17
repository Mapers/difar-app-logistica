import 'package:difar_logistica/core/codigos.dart';
import 'package:difar_logistica/core/proyeccion.dart';
import 'package:difar_logistica/lectura/ajustes.dart';
import 'package:difar_logistica/lectura/pantalla_ajustes.dart';
import 'package:difar_logistica/lectura/pantalla_lista.dart';
import 'package:difar_logistica/lectura/sesion_lectura.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('la lista muestra cantidades y suma/resta', (tester) async {
    final s = SesionLectura()..registrar('7501031311309', 'EAN-13', DateTime(2026));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListaLecturas(sesion: s))));
    expect(find.text('7501031311309'), findsOneWidget);

    await tester.tap(find.byTooltip('Sumar'));
    await tester.pump();
    expect(s.totalUnidades, 2);

    await tester.tap(find.byTooltip('Restar'));
    await tester.tap(find.byTooltip('Restar'));
    await tester.pump();
    expect(find.textContaining('Toca el boton para escanear'), findsOneWidget);
  });

  testWidgets('ajustes guarda el grupo de formatos', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final a = Ajustes(await SharedPreferences.getInstance());
    expect(a.grupo, GrupoFormatos.todos); // automatico por defecto

    await tester.pumpWidget(MaterialApp(home: PantallaAjustes(ajustes: a)));
    await tester.tap(find.text(GrupoFormatos.productos.etiqueta));
    await tester.pump();
    expect(a.grupo, GrupoFormatos.productos);
  });

  group('proyeccion', () {
    test('BoxFit.cover: imagen 720x1280 en vista 360x800', () {
      // escala = max(360/720, 800/1280) = 0.625 -> imagen 450x800, sobran 45 px por lado.
      final p = proyectarACubrir(const [Offset(360, 640), Offset(72, 0)], const Size(720, 1280), const Size(360, 800));
      expect(p[0], const Offset(180, 400));
      expect(p[1], const Offset(0, 0));
      expect(proyectarACubrir(const [Offset(1, 1)], Size.zero, const Size(1, 1)), isEmpty);
    });

    List<Offset> caja(double cx, double cy) =>
        [Offset(cx - 10, cy - 5), Offset(cx + 10, cy - 5), Offset(cx + 10, cy + 5), Offset(cx - 10, cy + 5)];

    test('el apuntado es el mas cercano al centro de lo que se ve', () {
      const imagen = Size(720, 1280);
      const vista = Size(200, 200); // ventanita cuadrada: ve solo el centro de la imagen
      final codigos = [caja(360, 500), caja(380, 650), caja(360, 900)];
      expect(indiceApuntado(codigos, imagen, vista), 1);
    });

    test('lo que queda fuera de la vista no se apunta', () {
      const imagen = Size(720, 1280);
      const vista = Size(200, 200);
      // Escala 200/720: se ve y de 280 a 1000 de la imagen; y=100 queda afuera.
      expect(indiceApuntado([caja(360, 100)], imagen, vista), isNull);
      expect(indiceApuntado(const [], imagen, vista), isNull);
    });
  });

  test('codigos visibles: los que tienen el centro dentro de la vista', () {
    List<Offset> caja(double cx, double cy) =>
        [Offset(cx - 10, cy - 5), Offset(cx + 10, cy - 5), Offset(cx + 10, cy + 5), Offset(cx - 10, cy + 5)];
    const imagen = Size(720, 1280);
    const vista = Size(200, 200); // ve y de 280 a 1000 de la imagen
    expect(indicesVisibles([caja(360, 500), caja(360, 100), caja(380, 900)], imagen, vista), [0, 2]);
  });
}
