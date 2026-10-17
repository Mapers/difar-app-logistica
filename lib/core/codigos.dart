import 'package:mobile_scanner/mobile_scanner.dart';

/// Grupos de simbologias. Leer solo las que se usan es lo que mas acelera
/// la deteccion: el decodificador prueba menos formatos por cuadro.
enum GrupoFormatos {
  productos('Productos (EAN / UPC)', [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ]),
  logistica('Logistica (1D: EAN, Code 128, ITF...)', [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.itf14,
    BarcodeFormat.codabar,
  ]),
  dosD('2D (QR, DataMatrix, PDF417)', [
    BarcodeFormat.qrCode,
    BarcodeFormat.dataMatrix,
    BarcodeFormat.pdf417,
    BarcodeFormat.aztec,
  ]),
  todos('Todos los formatos', []);

  const GrupoFormatos(this.etiqueta, this.formatos);

  final String etiqueta;

  /// Lista vacia = todos los formatos soportados.
  final List<BarcodeFormat> formatos;
}

String nombreFormato(BarcodeFormat f) => switch (f) {
      BarcodeFormat.ean13 => 'EAN-13',
      BarcodeFormat.ean8 => 'EAN-8',
      BarcodeFormat.upcA => 'UPC-A',
      BarcodeFormat.upcE => 'UPC-E',
      BarcodeFormat.code128 => 'Code 128',
      BarcodeFormat.code39 => 'Code 39',
      BarcodeFormat.code93 => 'Code 93',
      BarcodeFormat.codabar => 'Codabar',
      BarcodeFormat.itf14 => 'ITF',
      BarcodeFormat.qrCode => 'QR',
      BarcodeFormat.dataMatrix => 'DataMatrix',
      BarcodeFormat.pdf417 => 'PDF417',
      BarcodeFormat.aztec => 'Aztec',
      _ => f.name,
    };

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
