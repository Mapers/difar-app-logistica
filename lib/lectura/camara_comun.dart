import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/codigos.dart';
import 'ajustes.dart';

/// Camara configurada para leer rapido:
/// * solo los formatos del grupo elegido (menos trabajo por cuadro);
/// * `DetectionSpeed.unrestricted`: analiza todos los cuadros, los repetidos
///   los filtra [SesionLectura], asi un codigo nuevo se lee al instante;
/// * 1280x720 (Android usa 640x480 de fabrica: no alcanza para codigos chicos
///   o lejanos); 1920x1080 en conteo multiple, donde cada codigo sale mas chico.
MobileScannerController crearCamara(Ajustes ajustes, {bool multiple = false, bool autoStart = true}) {
  return MobileScannerController(
    autoStart: autoStart,
    formats: ajustes.grupo.formatos,
    detectionSpeed: DetectionSpeed.unrestricted,
    cameraResolution: multiple ? const Size(1920, 1080) : const Size(1280, 720),
    autoZoom: ajustes.autoZoom,
  );
}

/// Un codigo visto en el ultimo cuadro.
class CodigoVisto {
  CodigoVisto(this.valor, this.formato, this.esquinas);

  final String valor;
  final String formato;
  final List<Offset> esquinas;
}

List<CodigoVisto> codigosDe(BarcodeCapture captura) => [
      for (final b in captura.barcodes)
        if (b.rawValue != null && b.rawValue!.isNotEmpty)
          CodigoVisto(b.rawValue!, nombreFormato(b.format), b.corners),
    ];

class BotonSobreCamara extends StatelessWidget {
  const BotonSobreCamara({super.key, required this.icono, required this.tooltip, required this.onPressed});

  final IconData icono;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icono, size: 20),
      color: Colors.white,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(backgroundColor: Colors.black45),
    );
  }
}

class ErrorCamara extends StatelessWidget {
  const ErrorCamara({super.key, required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final texto = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? 'Sin permiso de camara. Activalo en Ajustes del telefono > Apps > DIFAR Logistica.'
        : 'No se pudo abrir la camara (${error.errorCode.name}).';
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(texto,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ),
    );
  }
}

class DialogoManual extends StatefulWidget {
  const DialogoManual({super.key});

  @override
  State<DialogoManual> createState() => _DialogoManualState();
}

class _DialogoManualState extends State<DialogoManual> {
  final _texto = TextEditingController();
  String? _aviso;

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  void _aceptar() {
    final codigo = _texto.text.trim();
    if (codigo.isEmpty) return;
    // Si parece un EAN/UPC/GTIN, se avisa una vez si el digito verificador no cuadra.
    final esGtin = RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(codigo);
    if (esGtin && !digitoGs1Valido(codigo) && _aviso == null) {
      setState(() => _aviso = 'El digito verificador no coincide. Revisa el codigo o toca Agregar otra vez.');
      return;
    }
    Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingresar codigo'),
      content: TextField(
        controller: _texto,
        autofocus: true,
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(labelText: 'Codigo', errorText: _aviso, errorMaxLines: 3),
        onChanged: (_) {
          if (_aviso != null) setState(() => _aviso = null);
        },
        onSubmitted: (_) => _aceptar(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _aceptar, child: const Text('Agregar')),
      ],
    );
  }
}
