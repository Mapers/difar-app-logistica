import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/codigos.dart';

/// Preferencias del escaner, guardadas en el telefono.
class Ajustes extends ChangeNotifier {
  Ajustes(this._prefs);

  final SharedPreferences? _prefs;

  GrupoFormatos get grupo => GrupoFormatos.values.firstWhere(
        (g) => g.name == _prefs?.getString('grupo'),
        // Por defecto reconoce cualquier tipo de codigo, sin elegir nada.
        orElse: () => GrupoFormatos.todos,
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

  /// 1080p: los codigos chicos o lejanos se leen al primer intento; 720p
  /// procesa mas cuadros por segundo. Para comparar en el telefono.
  bool get altaResolucion => _prefs?.getBool('alta_resolucion') ?? true;
  set altaResolucion(bool v) => _set(() => _prefs?.setBool('alta_resolucion', v));

  /// Exposicion propia: tiempo corto fijo (1/250 s) y sensibilidad segun el
  /// brillo que mide el motor, para que el movimiento no borronee las barras.
  bool get exposicionPropia => _prefs?.getBool('exposicion_propia') ?? true;
  set exposicionPropia(bool v) => _set(() => _prefs?.setBool('exposicion_propia', v));

  /// Acerca la camara (2x) sola cuando los codigos salen chicos o lejos.
  bool get zoomAuto => _prefs?.getBool('zoom_auto') ?? true;
  set zoomAuto(bool v) => _set(() => _prefs?.setBool('zoom_auto', v));

  /// Enciende la linterna sola cuando hay poca luz.
  bool get linternaAuto => _prefs?.getBool('linterna_auto') ?? true;
  set linternaAuto(bool v) => _set(() => _prefs?.setBool('linterna_auto', v));

  void _set(void Function() guardar) {
    guardar();
    notifyListeners();
  }
}
