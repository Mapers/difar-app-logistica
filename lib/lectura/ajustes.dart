import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/codigos.dart';

/// Con que motor leer. Los dos a la vez es lo que mas lee (cada uno saca
/// codigos que el otro no); solo uno gasta menos bateria.
enum MotorLectura {
  ambos('C++ y ML Kit a la vez', 'Lo que mas lee: cada motor saca codigos que el otro no.'),
  cpp('Solo motor C++', 'zxing-cpp con preparacion de imagen: oscuridad, reflejos, invertidos, girados.'),
  mlkit('Solo ML Kit', 'Motor de Google: muy bueno con codigos curvos o desenfocados.');

  const MotorLectura(this.etiqueta, this.descripcion);

  final String etiqueta;
  final String descripcion;
}

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

  MotorLectura get motor => MotorLectura.values.firstWhere(
        (m) => m.name == _prefs?.getString('motor'),
        orElse: () => MotorLectura.ambos,
      );
  set motor(MotorLectura v) => _set(() => _prefs?.setString('motor', v.name));

  /// 1080p: los codigos chicos o lejanos se leen al primer intento; 720p
  /// procesa mas cuadros por segundo. Para comparar en el telefono.
  bool get altaResolucion => _prefs?.getBool('alta_resolucion') ?? true;
  set altaResolucion(bool v) => _set(() => _prefs?.setBool('alta_resolucion', v));

  /// Enciende la linterna sola cuando hay poca luz.
  bool get linternaAuto => _prefs?.getBool('linterna_auto') ?? true;
  set linternaAuto(bool v) => _set(() => _prefs?.setBool('linterna_auto', v));

  void _set(void Function() guardar) {
    guardar();
    notifyListeners();
  }
}
