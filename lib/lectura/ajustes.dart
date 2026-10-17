import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/codigos.dart';

/// Preferencias del escaner, guardadas en el telefono.
class Ajustes extends ChangeNotifier {
  Ajustes(this._prefs);

  final SharedPreferences? _prefs;

  GrupoFormatos get grupo => GrupoFormatos.values.firstWhere(
        (g) => g.name == _prefs?.getString('grupo'),
        orElse: () => GrupoFormatos.logistica,
      );
  set grupo(GrupoFormatos v) => _set(() => _prefs?.setString('grupo', v.name));

  /// Si un codigo ya leido vuelve a pasar, suma 1 a su cantidad.
  bool get sumarRepetidos => _prefs?.getBool('sumar') ?? true;
  set sumarRepetidos(bool v) => _set(() => _prefs?.setBool('sumar', v));

  /// Tiempo minimo antes de volver a contar el MISMO codigo.
  int get esperaMs => _prefs?.getInt('espera') ?? 1500;
  set esperaMs(int v) => _set(() => _prefs?.setInt('espera', v));

  bool get vibrar => _prefs?.getBool('vibrar') ?? true;
  set vibrar(bool v) => _set(() => _prefs?.setBool('vibrar', v));

  bool get sonido => _prefs?.getBool('sonido') ?? true;
  set sonido(bool v) => _set(() => _prefs?.setBool('sonido', v));

  /// Acerca la camara sola si el codigo esta lejos (solo Android).
  bool get autoZoom => _prefs?.getBool('autozoom') ?? true;
  set autoZoom(bool v) => _set(() => _prefs?.setBool('autozoom', v));

  void _set(void Function() guardar) {
    guardar();
    notifyListeners();
  }
}
