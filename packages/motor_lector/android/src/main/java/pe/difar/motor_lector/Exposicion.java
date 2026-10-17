package pe.difar.motor_lector;

import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.util.Range;
import android.util.Rational;
import android.util.Size;

import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;

/**
 * Exposicion para leer codigos en movimiento (como los SDK comerciales). Es la unica duena de
 * las opciones Camera2 de la sesion (cada cambio reemplaza todas), en este orden:
 *
 * <ol>
 *   <li><b>propia</b>: tiempo corto fijo (1/250 s) e ISO en lazo cerrado con el brillo que mide
 *       el motor. Si la camara dice MANUAL_SENSOR, o si no lo dice pero al probarlo el sensor
 *       respeta el tiempo pedido (Samsung a veces no lo declara).
 *   <li><b>auto corta</b>: la automatica, con los cuadros por segundo fijos lo mas alto posible
 *       (60 si el sensor puede: tope de 16 ms) y compensacion negativa para empujarla a tiempos
 *       mas cortos cuando sobra luz.
 *   <li><b>auto</b>: la automatica a cuadros fijos (se apago la opcion).
 * </ol>
 */
final class Exposicion {
  static final long CORTA_NS = 4_000_000L; // 1/250 s
  static final long MAXIMA_NS = 16_000_000L; // con muy poca luz, antes que ruido extremo
  static final int OBJETIVO = 110; // brillo buscado (0..255)

  enum Modo { INICIO, PRUEBA, PROPIA, AUTO_CORTA, AUTO }

  final boolean declaraManual;
  final int fps;
  final String diagnostico;
  private final int isoMin, isoMax;
  private final long expMin;
  private final Range<Integer> rangoEv;
  private final float pasoEv;

  /** Ultimo tiempo e ISO reportados por la camara. */
  volatile long expActual;
  volatile int isoActual;
  volatile int resultados;

  private volatile Modo modo = Modo.INICIO;
  private boolean activa;
  private double luz; // exposicion total = ns * ISO
  private long expFijada;
  private int isoFijado;
  private boolean linterna;
  private int cuadros, resultadosAlFijar;
  private int ev; // compensacion en pasos del sensor
  private long expSinEv;

  Exposicion(Camera camara, Size analisis, Size previa, boolean activa) {
    this.activa = activa;
    final Camera2CameraInfo info = Camera2CameraInfo.from(camara.getCameraInfo());
    final int[] capacidades = info.getCameraCharacteristic(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES);
    boolean conManual = false;
    final StringBuilder caps = new StringBuilder();
    if (capacidades != null) {
      for (int c : capacidades) {
        if (c == CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) conManual = true;
        caps.append(caps.length() == 0 ? "" : ",").append(c);
      }
    }
    final Range<Integer> iso = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE);
    final Range<Long> exp = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE);
    declaraManual = conManual && iso != null && exp != null && exp.getLower() <= CORTA_NS;
    isoMin = iso == null ? 100 : iso.getLower();
    isoMax = iso == null ? 1600 : iso.getUpper();
    expMin = exp == null ? 100_000L : exp.getLower();
    final Range<Integer> r = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
    rangoEv = r == null ? new Range<>(0, 0) : r;
    final Rational paso = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP);
    pasoEv = paso == null ? 0 : paso.floatValue();

    // Cuadros por segundo: el rango fijo mas alto (hasta 60) que la automatica acepte y que los
    // dos flujos (analisis YUV y vista previa) puedan dar a su tamano.
    final StreamConfigurationMap mapa = info.getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    long minCuadro = 0;
    try {
      if (mapa != null && analisis != null) minCuadro = Math.max(minCuadro, mapa.getOutputMinFrameDuration(ImageFormat.YUV_420_888, analisis));
      if (mapa != null && previa != null) minCuadro = Math.max(minCuadro, mapa.getOutputMinFrameDuration(SurfaceTexture.class, previa));
    } catch (Exception e) {
      minCuadro = 33_333_333L;
    }
    final double fpsMax = minCuadro > 0 ? 1e9 / minCuadro : 30;
    final Range<Integer>[] rangos = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
    int mejor = 30;
    final StringBuilder lista = new StringBuilder();
    if (rangos != null) {
      for (Range<Integer> x : rangos) {
        lista.append(lista.length() == 0 ? "" : ",").append(x.getLower()).append('-').append(x.getUpper());
        if (x.getLower().equals(x.getUpper()) && x.getUpper() <= 60 && x.getUpper() <= fpsMax + 0.5 && x.getUpper() > mejor) {
          mejor = x.getUpper();
        }
      }
    }
    fps = mejor;
    final Integer nivel = info.getCameraCharacteristic(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL);
    diagnostico = "nivel=" + nivel + " capacidades=[" + caps + "] fps_ae=[" + lista + "] fps_max_flujos="
        + Math.round(fpsMax) + " iso=" + isoMin + "-" + isoMax + " exp_min_us=" + expMin / 1000 + " ev=" + rangoEv
        + "x" + pasoEv;
  }

  String modo() {
    switch (modo) {
      case PROPIA:
        return "propia";
      case PRUEBA:
        return "probando_propia";
      case AUTO_CORTA:
        return "auto_corta(ev=" + Math.round(ev * pasoEv * 10) / 10.0 + ")";
      case AUTO:
        return "auto";
      default:
        return "inicio";
    }
  }

  synchronized CaptureRequestOptions activar(boolean si) {
    activa = si;
    if (!si) {
      modo = Modo.AUTO;
      return opcionesAuto();
    }
    modo = Modo.INICIO;
    resultados = 0;
    return opcionesAuto();
  }

  /** Opciones al encender (antes de medir la luz). */
  synchronized CaptureRequestOptions inicial() {
    modo = activa ? Modo.INICIO : Modo.AUTO;
    return opcionesAuto();
  }

  /**
   * Con cada cuadro analizado ([brillo] y [quemados] del motor). Devuelve las opciones a aplicar,
   * o null si no hay que cambiar nada.
   */
  synchronized CaptureRequestOptions ajustar(int brillo, int quemados) {
    switch (modo) {
      case INICIO:
        // Unos cuadros en automatico para tomar su medida de la luz.
        if (resultados < 8 || expActual <= 0 || isoActual <= 0) return null;
        luz = (double) expActual * isoActual;
        expSinEv = expActual;
        cuadros = 0;
        modo = Modo.PRUEBA;
        resultadosAlFijar = resultados;
        return fijar();
      case PRUEBA:
        return null; // lo decide verificar()
      case PROPIA:
        return corregirPropia(brillo, quemados);
      case AUTO_CORTA:
        return corregirEv(brillo);
      default:
        return null;
    }
  }

  private CaptureRequestOptions corregirPropia(int brillo, int quemados) {
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

  /**
   * Automatica: si la exposicion es larga (borronea) y hay brillo de sobra, se baja la
   * compensacion para que la camara acorte el tiempo; si la imagen queda oscura, se sube. Si
   * bajar la compensacion no acorta el tiempo (la camara baja el ISO), se deja en 0.
   */
  private CaptureRequestOptions corregirEv(int brillo) {
    if (pasoEv <= 0 || ++cuadros % 6 != 0) return null;
    final int un = Math.max(1, Math.round(0.33f / pasoEv)); // ~1/3 EV
    int nuevo = ev;
    if (ev == 0) expSinEv = expActual;
    if (expActual > 8_500_000L && brillo > 75) {
      nuevo = Math.max(rangoEv.getLower(), Math.max(ev - un, Math.round(-2f / pasoEv)));
    } else if (brillo < 55 || (brillo < 80 && expActual <= 6_000_000L)) {
      nuevo = Math.min(0, ev + un);
    }
    // A -1 EV o menos sin acortar el tiempo: no sirve en esta camara.
    if (nuevo < ev && ev * pasoEv <= -1f && expActual >= expSinEv * 0.9) nuevo = 0;
    if (nuevo == ev) return null;
    ev = nuevo;
    return opcionesAuto();
  }

  boolean probando() {
    return modo == Modo.PRUEBA;
  }

  /**
   * Un rato despues de pedir manual: si el sensor respeta el tiempo pedido queda la propia; si
   * no (o dejo de entregar cuadros), la automatica corta. Devuelve opciones a aplicar o null.
   */
  synchronized CaptureRequestOptions verificar() {
    if (modo != Modo.PRUEBA) return null;
    if (resultados - resultadosAlFijar >= 12 && Math.abs(expActual - expFijada) <= expFijada * 0.3) {
      modo = Modo.PROPIA;
      cuadros = 0;
      return null;
    }
    modo = Modo.AUTO_CORTA;
    ev = 0;
    cuadros = 0;
    return opcionesAuto();
  }

  synchronized CaptureRequestOptions cambiarLinterna(boolean encendida) {
    linterna = encendida;
    return modo == Modo.PROPIA || modo == Modo.PRUEBA ? fijar() : null;
  }

  private CaptureRequestOptions.Builder base() {
    return new CaptureRequestOptions.Builder()
        .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, new Range<>(fps, fps));
  }

  private CaptureRequestOptions opcionesAuto() {
    final CaptureRequestOptions.Builder b = base();
    if (ev != 0 && modo == Modo.AUTO_CORTA) b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, ev);
    return b.build();
  }

  private CaptureRequestOptions fijar() {
    long exp = Math.max(CORTA_NS, expMin);
    double iso = luz / exp;
    if (iso > isoMax) {
      exp = (long) Math.min(luz / isoMax, Math.min(MAXIMA_NS, 1_000_000_000L / fps));
      iso = isoMax;
    } else if (iso < isoMin) {
      exp = (long) Math.max(luz / isoMin, expMin);
      iso = isoMin;
    }
    expFijada = exp;
    isoFijado = (int) Math.round(iso);
    luz = (double) expFijada * isoFijado; // lo que de verdad se pidio (con topes)
    return base()
        .setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
        .setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, expFijada)
        .setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, isoFijado)
        .setCaptureRequestOption(CaptureRequest.SENSOR_FRAME_DURATION, 1_000_000_000L / fps)
        .setCaptureRequestOption(CaptureRequest.FLASH_MODE,
            linterna ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF)
        .build();
  }
}
