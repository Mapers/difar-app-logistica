package pe.difar.difar_logistica

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Se crea una sola vez: ToneGenerator suena sin la demora de cargar un audio.
    private var tono: ToneGenerator? = null
    private var canalTono = -1

    // Suena por el volumen multimedia; si esta en 0 usa el de notificaciones,
    // para que el pitido no desaparezca sin que el operario se de cuenta.
    private fun generador(): ToneGenerator {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val canal = if (audio.getStreamVolume(AudioManager.STREAM_MUSIC) > 0) {
            AudioManager.STREAM_MUSIC
        } else {
            AudioManager.STREAM_NOTIFICATION
        }
        val actual = tono
        if (actual != null && canal == canalTono) return actual
        actual?.release()
        return ToneGenerator(canal, ToneGenerator.MAX_VOLUME).also {
            tono = it
            canalTono = canal
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "difar/pitido")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pitido" -> {
                        val repetido = call.argument<Boolean>("repetido") ?: false
                        tocar(
                            if (repetido) ToneGenerator.TONE_PROP_BEEP2 else ToneGenerator.TONE_PROP_BEEP,
                            if (repetido) 70 else 120,
                        )
                        result.success(null)
                    }
                    // Tono grave doble, claramente distinto al pitido de exito.
                    "error" -> {
                        tocar(ToneGenerator.TONE_PROP_NACK, 400)
                        result.success(null)
                    }
                    "vibrar" -> {
                        val patron = call.argument<List<Int>>("patron")?.map { it.toLong() }?.toLongArray()
                        if (patron != null) vibrar(patron)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun tocar(tipo: Int, ms: Int) {
        try {
            generador().startTone(tipo, ms)
        } catch (_: RuntimeException) {
            // Sin audio disponible: queda la vibracion.
        }
    }

    private fun vibrar(patron: LongArray) {
        val vibrador = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrador.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrador.vibrate(VibrationEffect.createWaveform(patron, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrador.vibrate(patron, -1)
        }
    }

    override fun onDestroy() {
        tono?.release()
        tono = null
        super.onDestroy()
    }
}
