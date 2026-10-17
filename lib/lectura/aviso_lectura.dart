import 'package:flutter/services.dart';

/// Sonido y vibracion al leer y al fallar. Todo es nativo (ToneGenerator y
/// Vibrator en Android, sonidos del sistema en iOS): sin demora al sonar, y la
/// vibracion no depende de que el telefono tenga activada la "respuesta tactil".
class AvisoLectura {
  static const _canal = MethodChannel('difar/pitido');

  /// Pitido agudo y corto + vibracion corta. Repetido = mas suave.
  static Future<void> leido({required bool sonido, required bool vibrar, bool repetido = false}) async {
    if (vibrar) await _vibrar(repetido ? const [0, 30] : const [0, 70], repetido ? 'suave' : 'fuerte');
    if (sonido) await _sonar('pitido', {'repetido': repetido}, SystemSoundType.click);
  }

  /// No se pudo leer: tono grave doble (distinto al de exito) + doble vibracion larga.
  static Future<void> fallo({required bool sonido, required bool vibrar}) async {
    if (vibrar) await _vibrar(const [0, 180, 100, 180], 'error');
    if (sonido) await _sonar('error', const {}, SystemSoundType.alert);
  }

  static Future<void> _sonar(String metodo, Map<String, Object> args, SystemSoundType respaldo) async {
    try {
      await _canal.invokeMethod<void>(metodo, args);
    } on MissingPluginException {
      await SystemSound.play(respaldo);
    } on PlatformException {
      await SystemSound.play(respaldo);
    }
  }

  /// [patron] en ms: espera, vibra, espera, vibra...
  static Future<void> _vibrar(List<int> patron, String tipo) async {
    try {
      await _canal.invokeMethod<void>('vibrar', {'patron': patron, 'tipo': tipo});
    } on Exception {
      await HapticFeedback.heavyImpact();
    }
  }
}
