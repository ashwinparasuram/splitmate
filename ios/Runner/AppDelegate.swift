import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeLedgerFromDeviceBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The SQLite ledger and receipts live in Documents. Keep them out of
  /// iCloud/iTunes device backups: backups happen only through SplitMate's
  /// own encrypted, opt-in flow.
  private func excludeLedgerFromDeviceBackup() {
    guard var docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? docs.setResourceValues(values)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
