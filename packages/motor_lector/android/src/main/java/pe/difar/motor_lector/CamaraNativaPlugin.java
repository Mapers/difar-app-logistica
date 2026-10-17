package pe.difar.motor_lector;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.util.Range;
import android.util.Size;
import android.view.Surface;

import androidx.annotation.NonNull;
import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.Camera2Interop;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.MeteringPoint;
import androidx.camera.core.Preview;
import androidx.camera.core.ResolutionInfo;
import androidx.camera.core.SurfaceOrientedMeteringPointFactory;
import androidx.camera.core.ZoomState;
import androidx.camera.core.resolutionselector.AspectRatioStrategy;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import androidx.camera.core.resolutionselector.ResolutionStrategy;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;

import com.google.common.util.concurrent.ListenableFuture;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import io.flutter.view.TextureRegistry;

/**
 * Camara nativa con CameraX, como la usan los SDK comerciales de lectura: la vista previa va a
 * una textura de Flutter y cada cuadro del analizador pasa directo (plano Y, sin copias) al
 * motor C++ por JNI. A Dart solo llega el resultado (JSON) por un EventChannel.
 */
public class CamaraNativaPlugin
    implements FlutterPlugin,
        ActivityAware,
        MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler,
        PluginRegistry.RequestPermissionsResultListener {
  private static final int PEDIDO_PERMISO = 0x4d4c;
  private static final int MODO_MOVIENDO = 16; // ML_MODO_MOVIENDO

  private MethodChannel canal;
  private EventChannel canalResultados;
  private volatile EventChannel.EventSink salida;
  private TextureRegistry texturas;
  private Context contexto;
  private ActivityPluginBinding actividad;
  private final Handler principal = new Handler(Looper.getMainLooper());

  private ExecutorService analizador;
  private ProcessCameraProvider proveedor;
  private Camera camara;
  private Preview previa;
  private ImageAnalysis analisis;
  private TextureRegistry.SurfaceProducer productor;
  private Exposicion exposicion;

  // Configuracion del motor (la cambia Dart mientras corre).
  private volatile int formatos, modo, presupuestoUs;
  private volatile boolean pausada, exposicionPropia = true, linterna;
  private int ronda;
  private volatile boolean verificando;
  private int analizados;

  // Giroscopio: velocidad de giro del telefono (rad/s, suavizada). Moviendo
  // rapido, la imagen sale corrida: el motor no gasta los pasos dificiles.
  // Con 4 ms de exposicion y ~1500 px de distancia focal, 1 rad/s corre la
  // imagen unos 6 px (2 barras de un EAN a 3 px/barra).
  static final float GIRO_MOVIENDO = 1.0f;
  private volatile float giro;
  private SensorManager sensores;
  private final SensorEventListener oyenteGiro = new SensorEventListener() {
    @Override
    public void onSensorChanged(SensorEvent e) {
      final float v = (float) Math.sqrt(e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2]);
      giro = giro * 0.6f + v * 0.4f;
    }

    @Override
    public void onAccuracyChanged(Sensor s, int precision) {}
  };

  // Lo que reporta la camara (hilo de la camara).
  private volatile int completados;

  private MethodChannel.Result permisoPendiente;
  private MethodCall llamadaPendiente;

  // ------------------------------------------------------------ registro

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding b) {
    contexto = b.getApplicationContext();
    texturas = b.getTextureRegistry();
    canal = new MethodChannel(b.getBinaryMessenger(), "difar/camara");
    canal.setMethodCallHandler(this);
    canalResultados = new EventChannel(b.getBinaryMessenger(), "difar/camara/resultados");
    canalResultados.setStreamHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding b) {
    detener();
    canal.setMethodCallHandler(null);
    canalResultados.setStreamHandler(null);
    if (analizador != null) analizador.shutdown();
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding b) {
    actividad = b;
    b.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding b) {
    onAttachedToActivity(b);
  }

  @Override
  public void onDetachedFromActivity() {
    detener();
    if (actividad != null) actividad.removeRequestPermissionsResultListener(this);
    actividad = null;
  }

  @Override
  public void onListen(Object argumentos, EventChannel.EventSink eventos) {
    salida = eventos;
  }

  @Override
  public void onCancel(Object argumentos) {
    salida = null;
  }

  // ------------------------------------------------------------ metodos

  @Override
  public void onMethodCall(@NonNull MethodCall llamada, @NonNull MethodChannel.Result r) {
    try {
      switch (llamada.method) {
        case "iniciar":
          iniciar(llamada, r);
          break;
        case "detener":
          detener();
          r.success(null);
          break;
        case "configurar":
          configurar(llamada);
          r.success(null);
          break;
        case "linterna":
          fijarLinterna(Boolean.TRUE.equals(llamada.argument("encendida")));
          r.success(null);
          break;
        case "zoom":
          if (camara != null) camara.getCameraControl().setZoomRatio(((Number) llamada.argument("aumento")).floatValue());
          r.success(null);
          break;
        case "enfocar":
          enfocar(((Number) llamada.argument("x")).floatValue(), ((Number) llamada.argument("y")).floatValue());
          r.success(null);
          break;
        case "reenfocar":
          if (camara != null) camara.getCameraControl().cancelFocusAndMetering();
          r.success(null);
          break;
        case "pausar":
          pausar(Boolean.TRUE.equals(llamada.argument("pausada")));
          r.success(null);
          break;
        default:
          r.notImplemented();
      }
    } catch (Exception e) {
      r.error("camara", e.toString(), null);
    }
  }

  private void configurar(MethodCall llamada) {
    if (llamada.hasArgument("formatos")) formatos = ((Number) llamada.argument("formatos")).intValue();
    if (llamada.hasArgument("modo")) modo = ((Number) llamada.argument("modo")).intValue();
    if (llamada.hasArgument("presupuestoUs")) presupuestoUs = ((Number) llamada.argument("presupuestoUs")).intValue();
    if (llamada.hasArgument("exposicionPropia")) {
      final boolean v = Boolean.TRUE.equals(llamada.argument("exposicionPropia"));
      if (v != exposicionPropia) {
        exposicionPropia = v;
        if (exposicion != null) aplicar(exposicion.activar(v));
      }
    }
  }

  private void iniciar(MethodCall llamada, MethodChannel.Result r) {
    if (actividad == null) {
      r.error("camara", "sin actividad", null);
      return;
    }
    final Activity a = actividad.getActivity();
    if (ContextCompat.checkSelfPermission(a, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
      if (permisoPendiente != null) {
        r.error("permiso", "ya se esta pidiendo el permiso", null);
        return;
      }
      permisoPendiente = r;
      llamadaPendiente = llamada;
      ActivityCompat.requestPermissions(a, new String[] {Manifest.permission.CAMERA}, PEDIDO_PERMISO);
      return;
    }
    configurar(llamada);
    final ListenableFuture<ProcessCameraProvider> futuro = ProcessCameraProvider.getInstance(contexto);
    futuro.addListener(() -> {
      try {
        proveedor = futuro.get();
        abrir(Boolean.TRUE.equals(llamada.argument("alta")), r);
      } catch (Exception e) {
        r.error("camara", e.toString(), null);
      }
    }, ContextCompat.getMainExecutor(contexto));
  }

  @Override
  public boolean onRequestPermissionsResult(int codigo, @NonNull String[] permisos, @NonNull int[] concedidos) {
    if (codigo != PEDIDO_PERMISO || permisoPendiente == null) return false;
    final MethodChannel.Result r = permisoPendiente;
    final MethodCall llamada = llamadaPendiente;
    permisoPendiente = null;
    llamadaPendiente = null;
    if (concedidos.length > 0 && concedidos[0] == PackageManager.PERMISSION_GRANTED) {
      iniciar(llamada, r);
    } else {
      r.error("permiso", "permiso de camara denegado", null);
    }
    return true;
  }

  private void abrir(boolean alta, MethodChannel.Result r) {
    detener();
    if (actividad == null) {
      r.error("camara", "sin actividad", null);
      return;
    }
    if (analizador == null) analizador = Executors.newSingleThreadExecutor();

    // Vista previa y analisis en 16:9: los dos ven el mismo campo, asi los recuadros caen
    // justo sobre los codigos.
    final ResolutionSelector seleccion = new ResolutionSelector.Builder()
        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
        .setResolutionStrategy(new ResolutionStrategy(alta ? new Size(1920, 1080) : new Size(1280, 720),
            ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
        .build();

    final Preview.Builder pb = new Preview.Builder().setResolutionSelector(seleccion);
    final Camera2Interop.Extender<Preview> extensor = new Camera2Interop.Extender<>(pb);
    // 30 cuadros/s fijos: con poca luz la automatica bajaba a 12-15 y alargaba la exposicion.
    extensor.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, new Range<>(30, 30));
    extensor.setSessionCaptureCallback(new CameraCaptureSession.CaptureCallback() {
      @Override
      public void onCaptureCompleted(@NonNull CameraCaptureSession s, @NonNull CaptureRequest pedido,
          @NonNull TotalCaptureResult res) {
        completados++;
        final Exposicion e = exposicion;
        if (e == null) return;
        final Long exp = res.get(CaptureResult.SENSOR_EXPOSURE_TIME);
        final Integer iso = res.get(CaptureResult.SENSOR_SENSITIVITY);
        if (exp != null) e.expActual = exp;
        if (iso != null) e.isoActual = iso;
        e.resultados++;
      }
    });
    previa = pb.build();

    analisis = new ImageAnalysis.Builder()
        .setResolutionSelector(seleccion)
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
        .build();
    analisis.setAnalyzer(analizador, this::analizar);

    final TextureRegistry.SurfaceProducer prod = texturas.createSurfaceProducer();
    productor = prod;
    previa.setSurfaceProvider(ContextCompat.getMainExecutor(contexto), pedido -> {
      prod.setCallback(new TextureRegistry.SurfaceProducer.Callback() {
        @Override
        public void onSurfaceAvailable() {}

        @Override
        public void onSurfaceCleanup() {
          pedido.invalidate();
        }
      });
      prod.setSize(pedido.getResolution().getWidth(), pedido.getResolution().getHeight());
      final Surface superficie = prod.getForcedNewSurface();
      pedido.provideSurface(superficie, ContextCompat.getMainExecutor(contexto), res -> superficie.release());
    });

    ronda = 0;
    analizados = 0;
    completados = 0;
    pausada = false;
    camara = proveedor.bindToLifecycle(
        (LifecycleOwner) actividad.getActivity(), CameraSelector.DEFAULT_BACK_CAMERA, previa, analisis);
    final ResolutionInfo ra = analisis.getResolutionInfo();
    final ResolutionInfo rp = previa.getResolutionInfo();
    sensores = (SensorManager) contexto.getSystemService(Context.SENSOR_SERVICE);
    final Sensor sensorGiro = sensores == null ? null : sensores.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
    if (sensorGiro != null) sensores.registerListener(oyenteGiro, sensorGiro, SensorManager.SENSOR_DELAY_GAME);
    exposicion = new Exposicion(camara, ra == null ? null : ra.getResolution(), rp == null ? null : rp.getResolution(),
        exposicionPropia);
    aplicar(exposicion.inicial());
    if (linterna) camara.getCameraControl().enableTorch(true);

    final Camera2CameraInfo info2 = Camera2CameraInfo.from(camara.getCameraInfo());
    final Integer giroSensor = info2.getCameraCharacteristic(CameraCharacteristics.SENSOR_ORIENTATION);
    final ResolutionInfo ri = previa.getResolutionInfo();
    final ZoomState zoom = camara.getCameraInfo().getZoomState().getValue();

    final Map<String, Object> m = new HashMap<>();
    m.put("textura", prod.id());
    m.put("giroListo", prod.handlesCropAndRotation());
    m.put("giroVista", ri == null ? (giroSensor == null ? 90 : giroSensor) : ri.getRotationDegrees());
    m.put("previaAncho", ri == null ? 1920 : ri.getResolution().getWidth());
    m.put("previaAlto", ri == null ? 1080 : ri.getResolution().getHeight());
    m.put("giroSensor", giroSensor == null ? 90 : giroSensor);
    m.put("zoomMin", zoom == null ? 1.0 : (double) zoom.getMinZoomRatio());
    m.put("zoomMax", zoom == null ? 1.0 : (double) zoom.getMaxZoomRatio());
    m.put("exposicionManual", exposicion.declaraManual);
    m.put("fps", exposicion.fps);
    m.put("isoMax", exposicion.isoMax);
    m.put("diagnostico", exposicion.diagnostico);
    m.put("nucleos", Runtime.getRuntime().availableProcessors());
    r.success(m);
  }

  private void detener() {
    if (sensores != null) sensores.unregisterListener(oyenteGiro);
    giro = 0;
    if (analisis != null) analisis.clearAnalyzer();
    if (proveedor != null) proveedor.unbindAll();
    if (productor != null) productor.release();
    productor = null;
    analisis = null;
    previa = null;
    camara = null;
    exposicion = null;
  }

  private void fijarLinterna(boolean encendida) {
    linterna = encendida;
    if (camara == null) return;
    final Exposicion e = exposicion;
    // Con exposicion manual la linterna va en las mismas opciones (FLASH_MODE):
    // enableTorch de CameraX vuelve a encender la automatica (en el A54 quedo
    // en 16,7 ms al apagar la linterna, registro v0.16).
    if (e != null && e.manual()) {
      aplicar(e.cambiarLinterna(encendida));
      return;
    }
    camara.getCameraControl().enableTorch(encendida);
    if (e != null) aplicar(e.cambiarLinterna(encendida));
  }

  /** [x], [y] normalizados (0..1) sobre el cuadro del analizador (orientacion del sensor). */
  private void enfocar(float x, float y) {
    if (camara == null || analisis == null) return;
    final MeteringPoint punto = new SurfaceOrientedMeteringPointFactory(1f, 1f, analisis).createPoint(x, y);
    // Solo enfoque: la exposicion la maneja Exposicion (o la automatica).
    camara.getCameraControl().startFocusAndMetering(
        new FocusMeteringAction.Builder(punto, FocusMeteringAction.FLAG_AF)
            .setAutoCancelDuration(4, TimeUnit.SECONDS)
            .build());
  }

  private void pausar(boolean pausar) {
    pausada = pausar;
    if (proveedor == null || previa == null || actividad == null) return;
    // Congelar: se suelta la vista previa (la textura queda con el ultimo cuadro).
    if (pausar) {
      proveedor.unbind(previa);
    } else if (!proveedor.isBound(previa)) {
      camara = proveedor.bindToLifecycle(
          (LifecycleOwner) actividad.getActivity(), CameraSelector.DEFAULT_BACK_CAMERA, previa);
    }
  }

  private void aplicar(CaptureRequestOptions opciones) {
    final Camera c = camara;
    if (opciones == null || c == null) return;
    principal.post(() -> {
      if (camara == c) Camera2CameraControl.from(c.getCameraControl()).setCaptureRequestOptions(opciones);
    });
  }

  // ------------------------------------------------------------ cuadros

  private void analizar(@NonNull ImageProxy img) {
    try {
      final EventChannel.EventSink s = salida;
      if (pausada || s == null) return;
      final ImageProxy.PlaneProxy y = img.getPlanes()[0];
      final long t0 = SystemClock.elapsedRealtimeNanos();
      final byte[] r = MotorNativo.leer(y.getBuffer(), img.getWidth(), img.getHeight(), y.getRowStride(),
          formatos, giro > GIRO_MOVIENDO ? modo | MODO_MOVIENDO : modo, presupuestoUs, ronda);
      if (r == null) return;
      final String motor = new String(r, StandardCharsets.UTF_8);
      ronda = numero(motor, "\"ronda\":", ronda);
      analizados++;

      final Exposicion e = exposicion;
      if (e != null && exposicionPropia) {
        aplicar(e.ajustar(numero(motor, "\"brillo\":", 128), numero(motor, "\"quemados\":", 0)));
        if (e.probando() && !verificando) {
          // Se acaba de pedir manual: en 1,5 s se ve si el sensor lo respeta.
          verificando = true;
          principal.postDelayed(() -> {
            verificando = false;
            if (exposicion == e) aplicar(e.verificar());
          }, 1500);
        }
      }
      // Edad del cuadro al terminar (si el reloj del sensor es el de arranque).
      final long edad = (SystemClock.elapsedRealtimeNanos() - img.getImageInfo().getTimestamp()) / 1_000_000L;
      final StringBuilder ev = new StringBuilder(motor.length() + 200);
      ev.append("{\"m\":").append(motor)
          .append(",\"ancho\":").append(img.getWidth())
          .append(",\"alto\":").append(img.getHeight())
          .append(",\"fila\":").append(y.getRowStride())
          .append(",\"giro\":").append(img.getImageInfo().getRotationDegrees())
          .append(",\"analizados\":").append(analizados)
          .append(",\"sensor\":").append(completados)
          .append(",\"msMotor\":").append((SystemClock.elapsedRealtimeNanos() - t0) / 1_000_000L)
          .append(",\"edad\":").append(edad >= 0 && edad < 5000 ? edad : -1)
          .append(",\"giroRad\":").append(Math.round(giro * 100) / 100.0);
      if (e != null) {
        ev.append(",\"exp\":").append(e.expActual)
            .append(",\"iso\":").append(e.isoActual)
            .append(",\"modoExp\":\"").append(e.modo()).append('"');
      }
      ev.append('}');
      final String texto = ev.toString();
      principal.post(() -> {
        final EventChannel.EventSink actual = salida;
        if (actual != null) actual.success(texto);
      });
    } catch (Throwable t) {
      final String error = t.toString();
      principal.post(() -> {
        final EventChannel.EventSink actual = salida;
        if (actual != null) actual.error("motor", error, null);
      });
    } finally {
      img.close();
    }
  }

  /** Lee el entero que sigue a [clave] en el JSON del motor. */
  private static int numero(String json, String clave, int otro) {
    int i = json.lastIndexOf(clave);
    if (i < 0) return otro;
    i += clave.length();
    int fin = i;
    while (fin < json.length() && (Character.isDigit(json.charAt(fin)) || json.charAt(fin) == '-')) fin++;
    try {
      return Integer.parseInt(json.substring(i, fin));
    } catch (NumberFormatException e) {
      return otro;
    }
  }
}
