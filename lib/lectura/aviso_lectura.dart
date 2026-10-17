import 'package:flutter/services.dart';

/// Pitido y vibracion al leer. El pitido es nativo (ToneGenerator en Android,
/// sonido del sistema en iOS) para que no haya demora al reproducirlo.
class AvisoLectura {
  static const _canal = MethodChannel('difar/pitido');

  static Future<void> leido({required bool sonido, required bool vibrar, bool repetido = false}) async {
    if (vibrar) {
      repetido ? HapticFeedback.lightImpact() : HapticFeedback.heavyImpact();
    }
    if (sonido) {
      try {
        await _canal.invokeMethod<void>('pitido', {'repetido': repetido});
      } on MissingPluginException {
        await SystemSound.play(SystemSoundType.click);
      } on PlatformException {
        await SystemSound.play(SystemSoundType.click);
      }
    }
  }
}
