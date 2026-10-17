package pe.difar.motor_lector;

import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.util.Range;

import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;

/**
 * Exposicion propia para leer codigos en movimiento (como los SDK comerciales): tiempo de
 * exposicion corto fijo (1/250 s) para que las barras no se borroneen, y la sensibilidad (ISO)
 * se ajusta en lazo cerrado con el brillo que mide el motor en el centro del cuadro. Arranca
 * con la del auto-exposicion de la camara (misma luz total) y de ahi se corrige.
 *
 * <p>Solo si la camara permite control manual (MANUAL_SENSOR); si no, queda la automatica.
 */
final class Exposicion {
  static final long CORTA_NS = 4_000_000L; // 1/250 s
  static final long MAXIMA_NS = 16_000_000L; // con muy poca luz, antes que ruido extremo
  static final long CUADRO_NS = 33_333_333L; // 30 cuadros/s
  static final int OBJETIVO = 110; // brillo buscado (0..255)

  final boolean posible;
  private final int isoMin, isoMax;
  private final long expMin;

  /** Ultimo tiempo e ISO reportados por la camara (en automatico o manual). */
  volatile long expActual;
  volatile int isoActual;
  volatile int resultados;

  private boolean manual;
  private double luz; // exposicion total = ns * ISO
  private long expFijada;
  private int isoFijado;
  private boolean linterna;
  private int cuadros;

  Exposicion(Camera camara) {
    final Camera2CameraInfo info = Camera2CameraInfo.from(camara.getCameraInfo());
    final int[] capacidades = info.getCameraCharacteristic(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES);
    boolean conManual = false;
    if (capacidades != null) {
      for (int c : capacidades) {
        if (c == CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) conManual = true;
      }
    }
    final Range<Integer> iso = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE);
    final Range<Long> exp = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE);
    posible = conManual && iso != null && exp != null && exp.getLower() <= CORTA_NS;
    isoMin = iso == null ? 100 : iso.getLower();
    isoMax = iso == null ? 800 : iso.getUpper();
    expMin = exp == null ? 100_000L : exp.getLower();
  }

  boolean manual() {
    return manual;
  }

  long expFijada() {
    return expFijada;
  }

  int isoFijado() {
    return isoFijado;
  }

  /**
   * Con cada cuadro analizado ([brillo] del motor). Devuelve las opciones a aplicar, o null si no
   * hay que cambiar nada.
   */
  synchronized CaptureRequestOptions ajustar(int brillo, int quemados) {
    if (!posible) return null;
    if (!manual) {
      // Unos cuadros en automatico para tomar su medida de la luz.
      if (resultados < 8 || expActual <= 0 || isoActual <= 0) return null;
      luz = (double) expActual * isoActual;
      manual = true;
      cuadros = 0;
      return fijar();
    }
    // El cambio tarda unos cuadros en llegar al sensor: se corrige cada 3.
    if (++cuadros % 3 != 0) return null;
    final int objetivo = quemados > 8 ? OBJETIVO - 25 : OBJETIVO;
    double factor = objetivo / (double) Math.max(brillo, 4);
    factor = Math.max(0.5, Math.min(2.0, factor));
    factor = Math.pow(factor, 0.6);
    if (Math.abs(factor - 1) < 0.07) return null;
    luz *= factor;
    return fijar();
  }

  synchronized CaptureRequestOptions cambiarLinterna(boolean encendida) {
    linterna = encendida;
    return manual ? fijar() : null;
  }

  private CaptureRequestOptions fijar() {
    long exp = Math.max(CORTA_NS, expMin);
    double iso = luz / exp;
    if (iso > isoMax) {
      exp = (long) Math.min(luz / isoMax, MAXIMA_NS);
      iso = isoMax;
    } else if (iso < isoMin) {
      exp = (long) Math.max(luz / isoMin, expMin);
      iso = isoMin;
    }
    expFijada = exp;
    isoFijado = (int) Math.round(iso);
    luz = (double) expFijada * isoFijado; // lo que de verdad se pidio (con topes)
    final CaptureRequestOptions.Builder b = new CaptureRequestOptions.Builder()
        .setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
        .setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, expFijada)
        .setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, isoFijado)
        .setCaptureRequestOption(CaptureRequest.SENSOR_FRAME_DURATION, CUADRO_NS)
        .setCaptureRequestOption(CaptureRequest.FLASH_MODE,
            linterna ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
    return b.build();
  }

  /** Vuelve a la automatica (se apago la opcion o se cerro la camara). */
  synchronized void soltar(Camera camara) {
    if (!manual) return;
    manual = false;
    Camera2CameraControl.from(camara.getCameraControl()).clearCaptureRequestOptions();
  }
}
