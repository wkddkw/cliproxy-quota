import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "com.wkddkw.cliproxy_quota/cache",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard let defaults = UserDefaults(suiteName: "group.com.wkddkw.cliproxyQuota") else {
        result(FlutterError(code: "APP_GROUP", message: "小组件共享存储不可用", details: nil))
        return
      }
      switch call.method {
      case "writeCache":
        guard let snapshot = call.arguments as? String else {
          result(FlutterError(code: "CACHE_FORMAT", message: "缓存格式错误", details: nil)); return
        }
        defaults.set(snapshot, forKey: "snapshot")
      case "clearCache": defaults.removeObject(forKey: "snapshot")
      default: result(FlutterMethodNotImplemented); return
      }
      WidgetCenter.shared.reloadTimelines(ofKind: "CLIProxyQuota")
      result(nil)
    }
  }
}
