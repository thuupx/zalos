import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let refreshTaskId = "dev.zalos.refresh"
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private var backgroundChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Lets flutter_local_notifications present and handle notifications.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshTaskId,
      using: nil
    ) { [weak self] task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleAppRefresh(task: refreshTask)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    backgroundChannel = FlutterMethodChannel(
      name: "dev.zalos/background",
      binaryMessenger: messenger
    )
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    beginKeepAliveTask(application)
    scheduleAppRefresh()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    endKeepAliveTask(application)
  }

  private func beginKeepAliveTask(_ application: UIApplication) {
    endKeepAliveTask(application)
    backgroundTaskId = application.beginBackgroundTask(withName: "dev.zalos.keepConnection") { [weak self] in
      self?.endKeepAliveTask(application)
    }
  }

  private func endKeepAliveTask(_ application: UIApplication) {
    if backgroundTaskId != .invalid {
      application.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }

  private func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private func handleAppRefresh(task: BGAppRefreshTask) {
    scheduleAppRefresh()
    var finished = false
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }
      finished = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = {
      finish(false)
    }
    DispatchQueue.main.async { [weak self] in
      guard let channel = self?.backgroundChannel else {
        finish(true)
        return
      }
      channel.invokeMethod("refresh", arguments: nil) { _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
          finish(true)
        }
      }
    }
  }
}
