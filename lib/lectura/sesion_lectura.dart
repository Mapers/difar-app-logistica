import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un codigo leido, con cuantas veces se conto.
class ItemLeido {
  ItemLeido({
    required this.codigo,
    required this.formato,
    required this.cantidad,
    required this.ultimaLectura,
  });

  final String codigo;
  final String formato;
  int cantidad;
  DateTime ultimaLectura;

  Map<String, Object> toJson() => {
        'codigo': codigo,
        'formato': formato,
        'cantidad': cantidad,
        'ultima': ultimaLectura.toIso8601String(),
      };

  factory ItemLeido.fromJson(Map<String, dynamic> j) => ItemLeido(
        codigo: j['codigo'] as String,
        formato: j['formato'] as String,
        cantidad: j['cantidad'] as int,
        ultimaLectura: DateTime.parse(j['ultima'] as String),
      );
}

/// Resultado de intentar registrar una lectura.
enum ResultadoLectura { nuevo, sumado, ignorado }

/// Lista de codigos de la sesion de conteo. Agrupa por codigo y suma
/// cantidades; una misma etiqueta frente a la camara no se cuenta dos veces
/// mientras no pase [espera] desde su ultima lectura.
class SesionLectura extends ChangeNotifier {
  SesionLectura({this.espera = const Duration(milliseconds: 1500), this.prefs});

  static const _clave = 'sesion_lectura_v1';

  Duration espera;
  final SharedPreferences? prefs;

  /// Orden: el ultimo leido primero.
  final List<ItemLeido> _items = [];
  List<ItemLeido> get items => List.unmodifiable(_items);

  int get totalUnidades => _items.fold(0, (s, i) => s + i.cantidad);

  /// Ultima vez que cada codigo paso por la camara (aunque se haya ignorado),
  /// para que mantenerlo enfocado no lo vuelva a contar.
  final Map<String, DateTime> _vistoPorUltimaVez = {};

  void cargar() {
    final crudo = prefs?.getString(_clave);
    if (crudo == null) return;
    try {
      final lista = jsonDecode(crudo) as List<dynamic>;
      _items
        ..clear()
        ..addAll(lista.map((e) => ItemLeido.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // Dato corrupto: se empieza de cero.
    }
  }

  /// [forzar] cuenta aunque el codigo se haya visto hace un instante
  /// (ingreso manual).
  ResultadoLectura registrar(String codigo, String formato, DateTime ahora,
      {bool sumarRepetidos = true, bool forzar = false}) {
    final visto = _vistoPorUltimaVez[codigo];
    _vistoPorUltimaVez[codigo] = ahora;
    if (!forzar && visto != null && ahora.difference(visto) < espera) {
      return ResultadoLectura.ignorado;
    }

    final i = _items.indexWhere((e) => e.codigo == codigo);
    if (i >= 0) {
      if (!sumarRepetidos) return ResultadoLectura.ignorado;
      final item = _items.removeAt(i)
        ..cantidad += 1
        ..ultimaLectura = ahora;
      _items.insert(0, item);
      _guardar();
      return ResultadoLectura.sumado;
    }
    _items.insert(
      0,
      ItemLeido(codigo: codigo, formato: formato, cantidad: 1, ultimaLectura: ahora),
    );
    _guardar();
    return ResultadoLectura.nuevo;
  }

  void cambiarCantidad(String codigo, int cantidad) {
    final i = _items.indexWhere((e) => e.codigo == codigo);
    if (i < 0) return;
    if (cantidad <= 0) {
      _items.removeAt(i);
    } else {
      _items[i].cantidad = cantidad;
    }
    _guardar();
  }

  void eliminar(String codigo) => cambiarCantidad(codigo, 0);

  void vaciar() {
    _items.clear();
    _vistoPorUltimaVez.clear();
    _guardar();
  }

  /// CSV separado por ';' (Excel en espanol lo abre directo).
  String aCsv() {
    final b = StringBuffer('codigo;formato;cantidad;ultima_lectura\n');
    for (final i in _items.reversed) {
      b.writeln('${i.codigo};${i.formato};${i.cantidad};${i.ultimaLectura.toIso8601String()}');
    }
    return b.toString();
  }

  void _guardar() {
    notifyListeners();
    prefs?.setString(_clave, jsonEncode(_items.map((e) => e.toJson()).toList()));
  }
}
