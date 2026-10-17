import 'package:motor_lector/motor_lector.dart';

/// Simbologias que lee la app, con su bit en el motor C++.
enum Simbologia {
  ean13('EAN-13', FormatosMotor.ean13),
  ean8('EAN-8', FormatosMotor.ean8),
  upcA('UPC-A', FormatosMotor.upcA),
  upcE('UPC-E', FormatosMotor.upcE),
  code128('Code 128', FormatosMotor.code128),
  code39('Code 39', FormatosMotor.code39),
  code93('Code 93', FormatosMotor.code93),
  itf('ITF', FormatosMotor.itf),
  codabar('Codabar', FormatosMotor.codabar),
  qr('QR', FormatosMotor.qr),
  dataMatrix('DataMatrix', FormatosMotor.dataMatrix),
  pdf417('PDF417', FormatosMotor.pdf417),
  aztec('Aztec', FormatosMotor.aztec);

  const Simbologia(this.nombre, this.bitMotor);

  final String nombre;
  final int bitMotor;

  /// Se exige leerlos igual en 2 cuadros seguidos: ITF, Code 39/93 y Codabar
  /// no tienen digito de control obligatorio (un pedazo del codigo tambien
  /// "decodifica"), y en el telefono salieron Code 128 sospechosos
  /// ($1PJN7B$0 / $1PKN7B$0 / $1PIN81J0 del mismo codigo).
  bool get sinControl =>
      this == itf || this == code39 || this == codabar || this == code93 || this == code128;

  static Simbologia? deMotor(int bit) {
    for (final s in values) {
      if (s.bitMotor == bit) return s;
    }
    return null;
  }

}

/// Grupos de simbologias. Leer solo las que se usan es lo que mas acelera
/// la deteccion: el motor prueba menos formatos por cuadro.
enum GrupoFormatos {
  todos('Automatico: todos los formatos', []),
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
  dosD('2D (QR, DataMatrix, PDF417)', [Simbologia.qr, Simbologia.dataMatrix, Simbologia.pdf417, Simbologia.aztec]);

  const GrupoFormatos(this.etiqueta, this.simbologias);

  final String etiqueta;

  /// Lista vacia = todos los formatos soportados.
  final List<Simbologia> simbologias;

  /// Mascara para el motor C++ (0 = todos).
  int get mascaraMotor => simbologias.fold(0, (m, s) => m | s.bitMotor);

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
