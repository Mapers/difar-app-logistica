import AudioToolbox
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "Pitido") {
      FlutterMethodChannel(name: "difar/pitido", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          if call.method == "pitido" {
            // 1057 = "Tink", corto y sin demora.
            AudioServicesPlaySystemSound(1057)
            result(nil)
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
