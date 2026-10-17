import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lectura/ajustes.dart';
import 'lectura/pantalla_principal.dart';
import 'lectura/sesion_lectura.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final prefs = await SharedPreferences.getInstance();
  final ajustes = Ajustes(prefs);
  final sesion = SesionLectura(prefs: prefs, espera: Duration(milliseconds: ajustes.esperaMs))..cargar();
  runApp(AppLogistica(sesion: sesion, ajustes: ajustes));
}

class AppLogistica extends StatelessWidget {
  const AppLogistica({super.key, required this.sesion, required this.ajustes});

  final SesionLectura sesion;
  final Ajustes ajustes;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIFAR Logistica',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B5FA5), useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B5FA5),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: PantallaPrincipal(sesion: sesion, ajustes: ajustes),
    );
  }
}
