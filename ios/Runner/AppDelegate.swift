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
          switch call.method {
          case "pitido":
            // 1057 = "Tink", corto y sin demora.
            AudioServicesPlaySystemSound(1057)
            result(nil)
          case "error":
            // 1073 = tono de error del sistema, distinto al de exito.
            AudioServicesPlaySystemSound(1073)
            result(nil)
          case "vibrar":
            let args = call.arguments as? [String: Any]
            if (args?["tipo"] as? String) == "error" {
              AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            } else {
              UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
            result(nil)
          default:
            result(FlutterMethodNotImplemented)
          }
        }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
