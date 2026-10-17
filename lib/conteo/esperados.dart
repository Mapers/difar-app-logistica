/// Lo que se espera contar (un pedido, una guia, un ingreso). Hoy viene de
/// [FuenteSimulada]; cuando exista el servicio de DIFAR se agrega otra fuente
/// con la misma interfaz y el conteo no cambia.
class Esperado {
  const Esperado(this.codigo, this.descripcion, this.cantidad);

  /// Codigo de barras (EAN/GTIN) tal como lo lee la camara.
  final String codigo;
  final String descripcion;
  final int cantidad;
}

class ListaEsperada {
  const ListaEsperada(this.id, this.nombre, this.items);

  final String id;
  final String nombre;
  final List<Esperado> items;

  int get unidades => items.fold(0, (s, e) => s + e.cantidad);

  Esperado? buscar(String codigo) {
    for (final e in items) {
      if (e.codigo == codigo) return e;
    }
    return null;
  }

  int cantidad(String codigo) => buscar(codigo)?.cantidad ?? 0;
}

abstract interface class FuenteEsperados {
  Future<List<ListaEsperada>> listas();
}

/// Listas de prueba con los codigos de las cajas que se usaron en las pruebas.
class FuenteSimulada implements FuenteEsperados {
  const FuenteSimulada();

  @override
  Future<List<ListaEsperada>> listas() async => const [
        ListaEsperada('1001', 'Pedido 1001 (simulado)', [
          Esperado('7753608815714', 'Producto A', 2),
          Esperado('7758467000875', 'Producto B', 2),
          Esperado('2050000610684', 'Producto C', 1),
          Esperado('7750082416093', 'Producto D', 2),
          Esperado('7750182000123', 'Producto E', 1),
        ]),
        ListaEsperada('1002', 'Pedido 1002 (simulado)', [
          Esperado('7753608815714', 'Producto A', 4),
          Esperado('7750082416093', 'Producto D', 1),
        ]),
      ];
}
