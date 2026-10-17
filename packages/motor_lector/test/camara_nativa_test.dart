import 'package:flutter_test/flutter_test.dart';
import 'package:motor_lector/camara_nativa.dart';
import 'package:motor_lector/motor_lector.dart';

void main() {
  test('el JSON de la camara nativa se lee igual que el resultado por FFI', () {
    const texto = '{"m":{"c":[{"t":"7750182000123","f":"EAN-13","b":1,"p":8,"i":0,"s":0,'
        '"x":[10,90,90,10],"y":[20,20,60,60]},{"t":"","f":"","b":0,"p":8,"i":0,"s":1,'
        '"x":[1,2,3,4],"y":[5,6,7,8]}],"i":{"brillo":120,"contraste":40,"quemados":2,"linterna":0,'
        '"pasos":3,"ronda":5,"us":21000,"nitidez":14,"ilegibles":0,"hilos":4,"regiones":2,'
        '"tp":[0,8000,0,0,0,0,0,0,9000,0]}},"ancho":1920,"alto":1080,"fila":1920,"giro":90,'
        '"analizados":7,"sensor":9,"msMotor":22,"edad":40,"exp":4000000,"iso":800,"modoExp":"propia"}';
    final c = CuadroNativo.desdeJson(texto);
    expect(c.ancho, 1920);
    expect(c.giro, 90);
    expect(c.iso, 800);
    expect(c.modoExposicion, 'propia');
    final r = c.resultado;
    expect(r.codigos, hasLength(2));
    expect(r.codigos.first.texto, '7750182000123');
    expect(r.codigos.first.paso, PasoMotor.detector);
    expect(r.codigos.first.esquinas[1], (90.0, 20.0));
    expect(r.codigos.last.sinLeer, isTrue);
    expect(r.info.siguienteRonda, 5);
    expect(r.info.tiempoPorPaso, {PasoMotor.rapido: 8000, PasoMotor.detector: 9000});
  });
}
