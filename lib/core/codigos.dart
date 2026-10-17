import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart' as ml;
import 'package:motor_lector/motor_lector.dart';

/// Simbologias que lee la app, con su bit del motor C++ y su formato de ML Kit.
enum Simbologia {
  ean13('EAN-13', FormatosMotor.ean13, ml.BarcodeFormat.ean13),
  ean8('EAN-8', FormatosMotor.ean8, ml.BarcodeFormat.ean8),
  upcA('UPC-A', FormatosMotor.upcA, ml.BarcodeFormat.upca),
  upcE('UPC-E', FormatosMotor.upcE, ml.BarcodeFormat.upce),
  code128('Code 128', FormatosMotor.code128, ml.BarcodeFormat.code128),
  code39('Code 39', FormatosMotor.code39, ml.BarcodeFormat.code39),
  code93('Code 93', FormatosMotor.code93, ml.BarcodeFormat.code93),
  itf('ITF', FormatosMotor.itf, ml.BarcodeFormat.itf),
  codabar('Codabar', FormatosMotor.codabar, ml.BarcodeFormat.codabar),
  qr('QR', FormatosMotor.qr, ml.BarcodeFormat.qrCode),
  dataMatrix('DataMatrix', FormatosMotor.dataMatrix, ml.BarcodeFormat.dataMatrix),
  pdf417('PDF417', FormatosMotor.pdf417, ml.BarcodeFormat.pdf417),
  aztec('Aztec', FormatosMotor.aztec, ml.BarcodeFormat.aztec);

  const Simbologia(this.nombre, this.bitMotor, this.mlkit);

  final String nombre;
  final int bitMotor;
  final ml.BarcodeFormat mlkit;

  /// Sin digito de control obligatorio: un pedazo del codigo tambien
  /// "decodifica". Se exige leerlos igual en 2 cuadros seguidos.
  bool get sinControl => this == itf || this == code39 || this == codabar || this == code93;

  static Simbologia? deMotor(int bit) {
    for (final s in values) {
      if (s.bitMotor == bit) return s;
    }
    return null;
  }

  static Simbologia? deMlkit(ml.BarcodeFormat f) {
    for (final s in values) {
      if (s.mlkit == f) return s;
    }
    return null;
  }
}

/// Grupos de simbologias. Leer solo las que se usan es lo que mas acelera
/// la deteccion: los motores prueban menos formatos por cuadro.
enum GrupoFormatos {
  productos('Productos (EAN / UPC)', [Simbologia.ean13, Simbologia.ean8, Simbologia.upcA, Simbologia.upcE]),
  logistica('Logistica (1D: EAN, Code 128, ITF...)', [
    Simbologia.ean13,
    Simbologia.ean8,
    Simbologia.upcA,
    Simbologia.upcE,
    Simbologia.code128,
    Simbologia.code39,
    Simbologia.code93,
    Simbologia.itf,
    Simbologia.codabar,
  ]),
  dosD('2D (QR, DataMatrix, PDF417)', [Simbologia.qr, Simbologia.dataMatrix, Simbologia.pdf417, Simbologia.aztec]),
  todos('Todos los formatos', []);

  const GrupoFormatos(this.etiqueta, this.simbologias);

  final String etiqueta;

  /// Lista vacia = todos los formatos soportados.
  final List<Simbologia> simbologias;

  /// Mascara para el motor C++ (0 = todos).
  int get mascaraMotor => simbologias.fold(0, (m, s) => m | s.bitMotor);

  List<ml.BarcodeFormat> get formatosMlkit =>
      simbologias.isEmpty ? const [ml.BarcodeFormat.all] : [for (final s in simbologias) s.mlkit];
}

/// Digito verificador GS1 (EAN-8, EAN-13, UPC-A, ITF-14, GTIN-14).
/// Sirve para validar codigos escritos a mano.
bool digitoGs1Valido(String codigo) {
  if (!RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(codigo)) return false;
  final digitos = codigo.split('').map(int.parse).toList();
  final control = digitos.removeLast();
  var suma = 0;
  for (var i = 0; i < digitos.length; i++) {
    // Desde la derecha: peso 3, 1, 3, 1...
    final peso = (digitos.length - i).isOdd ? 3 : 1;
    suma += digitos[i] * peso;
  }
  return (10 - suma % 10) % 10 == control;
}
