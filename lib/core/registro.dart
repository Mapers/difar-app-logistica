import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

/// Registro (log) de la app en un archivo del telefono, para compartirlo y
/// revisar que leyo, que motor, cuanto tardo y por que fallo.
///
/// Escribe en lotes (cada medio segundo) para no frenar la camara. Al pasar
/// de [_tope] bytes el archivo pasa a `.anterior` y se empieza otro: se
/// guardan como mucho dos.
class Registro {
  Registro._();

  static final Registro instancia = Registro._();

  static const _tope = 2 * 1024 * 1024;
  static final _hora = DateFormat('dd/MM HH:mm:ss.SSS');

  File? _archivo;
  final _pendiente = StringBuffer();
  Timer? _escribir;

  /// Para pruebas: guarda las lineas en memoria en vez de un archivo.
  List<String>? memoria;

  Future<void> iniciar() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _archivo = File('${dir.path}/registro_lector.txt');
      if (await _archivo!.exists() && await _archivo!.length() > _tope) {
        await _archivo!.rename('${_archivo!.path}.anterior');
        _archivo = File('${dir.path}/registro_lector.txt');
      }
    } catch (_) {
      _archivo = null; // sin archivo la app sigue igual
    }
  }

  /// [tipo]: palabra corta en mayusculas (LECTURA, FALLO, CAMARA, CUADROS...).
  void escribir(String tipo, String texto) {
    final linea = '${_hora.format(DateTime.now())} $tipo $texto';
    if (memoria != null) {
      memoria!.add(linea);
      return;
    }
    _pendiente.writeln(linea);
    _escribir ??= Timer(const Duration(milliseconds: 500), _volcar);
  }

  Future<void> _volcar() async {
    _escribir = null;
    final archivo = _archivo;
    if (archivo == null || _pendiente.isEmpty) return;
    final texto = _pendiente.toString();
    _pendiente.clear();
    try {
      await archivo.writeAsString(texto, mode: FileMode.append, flush: true);
      if (await archivo.length() > _tope) {
        await archivo.rename('${archivo.path}.anterior');
        _archivo = File(archivo.path);
      }
    } catch (_) {}
  }

  /// Archivo con todo el registro (el anterior + el actual) para compartir.
  Future<File?> paraCompartir() async {
    _escribir?.cancel();
    await _volcar();
    final actual = _archivo;
    if (actual == null) return null;
    final anterior = File('${actual.path}.anterior');
    final salida = File('${(await getTemporaryDirectory()).path}/registro_lector_'
        '${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.txt');
    final partes = <String>[
      if (await anterior.exists()) await anterior.readAsString(),
      if (await actual.exists()) await actual.readAsString(),
    ];
    await salida.writeAsString(partes.join());
    return salida;
  }

  Future<void> borrar() async {
    _pendiente.clear();
    final actual = _archivo;
    if (actual == null) return;
    for (final f in [actual, File('${actual.path}.anterior')]) {
      if (await f.exists()) await f.delete();
    }
    escribir('REGISTRO', 'borrado por el usuario');
  }
}

/// Atajo: `registrar('LECTURA', '...')`.
void registrar(String tipo, String texto) => Registro.instancia.escribir(tipo, texto);
