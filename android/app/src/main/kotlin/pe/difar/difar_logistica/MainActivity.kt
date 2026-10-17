package pe.difar.difar_logistica

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Se crea una sola vez: ToneGenerator suena sin la demora de cargar un audio.
    private var tono: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "difar/pitido")
            .setMethodCallHandler { call, result ->
                if (call.method == "pitido") {
                    val repetido = call.argument<Boolean>("repetido") ?: false
                    try {
                        val t = tono ?: ToneGenerator(AudioManager.STREAM_MUSIC, 90).also { tono = it }
                        t.startTone(
                            if (repetido) ToneGenerator.TONE_PROP_BEEP2 else ToneGenerator.TONE_PROP_BEEP,
                            if (repetido) 60 else 90,
                        )
                    } catch (_: RuntimeException) {
                        // Sin audio disponible: se queda solo la vibracion.
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        tono?.release()
        tono = null
        super.onDestroy()
    }
}
