import Flutter
import PushKit
import UIKit
import UserNotifications
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  private var voipRegistry: PKPushRegistry?
  private var pendingDeepLinkRoute: String?
  private var notificationChannel: FlutterMethodChannel?
  private static let apnsTokenDefaultsKey = "talkflix.apnsDeviceToken"
  private static var directCallsEnabled: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "TalkflixDirectCallsEnabled") as? Bool) ?? false
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if Self.directCallsEnabled {
      let registry = PKPushRegistry(queue: DispatchQueue.main)
      registry.delegate = self
      registry.desiredPushTypes = [PKPushType.voIP]
      voipRegistry = registry
    }
    let didLaunch = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    setupNativeNotificationChannel()
    DispatchQueue.main.async { [weak self] in
      self?.dispatchPendingDeepLinkIfNeeded()
    }
    return didLaunch
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleIncomingDeepLink(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL,
       handleIncomingDeepLink(url) {
      return true
    }
    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }

  private func handleIncomingDeepLink(_ url: URL) -> Bool {
    guard let route = routeForIncomingURL(url) else {
      return false
    }
    pendingDeepLinkRoute = route
    DispatchQueue.main.async { [weak self] in
      self?.dispatchPendingDeepLinkIfNeeded()
    }
    return true
  }

  private func dispatchPendingDeepLinkIfNeeded() {
    guard let route = pendingDeepLinkRoute else {
      return
    }
    guard let flutterViewController = window?.rootViewController as? FlutterViewController else {
      return
    }
    flutterViewController.pushRoute(route)
    pendingDeepLinkRoute = nil
  }

  private func routeForIncomingURL(_ url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let scheme = components.scheme?.lowercased() ?? ""
    let host = components.host?.lowercased() ?? ""
    let pathComponents = components.path.split(separator: "/").map(String.init)
    let isCustomScheme = scheme == "talkflix" && host == "app"
    let isUniversalLink =
      (scheme == "https" || scheme == "http")
      && (host == "talkflix.cc" || host == "www.talkflix.cc")
    guard isCustomScheme || isUniversalLink else {
      return nil
    }

    if pathComponents.count >= 2, pathComponents[0] == "s" {
      let token = pathComponents[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else {
        return nil
      }
      return "/s/\(token)"
    }

    if pathComponents.count >= 2, pathComponents[0] == "app", pathComponents[1] == "talk" {
      let shareText =
        components.queryItems?.first(where: { $0.name == "share" })?.value?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      guard !shareText.isEmpty else {
        return "/app/talk"
      }
      let encodedShareText =
        shareText.addingPercentEncoding(withAllowedCharacters: Self.routeQueryAllowed)
        ?? ""
      return "/app/talk?share=\(encodedShareText)"
    }

    let isLiveRoute =
      (pathComponents.count >= 2 && pathComponents[0] == "app" && pathComponents[1] == "live")
      || (pathComponents.count >= 1 && pathComponents[0] == "live")
    guard isLiveRoute else {
      return nil
    }

    let broadcastId: String
    if pathComponents.count >= 2 && pathComponents[0] == "live" {
      broadcastId = pathComponents[1].trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      broadcastId =
        components.queryItems?.first(where: { $0.name == "broadcastId" })?.value?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    if broadcastId.isEmpty {
      return "/app/live"
    }
    return "/app/live?broadcastId=\(broadcastId)"
  }

  private static let routeQueryAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return allowed
  }()

  private func setupNativeNotificationChannel() {
    guard notificationChannel == nil,
          let flutterViewController = window?.rootViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "cc.talkflix.app/notifications",
      binaryMessenger: flutterViewController.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "App delegate unavailable", details: nil))
        return
      }
      switch call.method {
      case "requestApnsToken":
        self.requestApnsToken(result: result)
      case "getApnsToken":
        result(UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey) ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    notificationChannel = channel
  }

  private func requestApnsToken(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
      granted, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "permission_error", message: error.localizedDescription, details: nil))
          return
        }
        guard granted else {
          result("")
          return
        }
        UIApplication.shared.registerForRemoteNotifications()
        result(UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey) ?? "")
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(token, forKey: Self.apnsTokenDefaultsKey)
    notificationChannel?.invokeMethod("apnsToken", arguments: token)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    notificationChannel?.invokeMethod(
      "apnsTokenError",
      arguments: error.localizedDescription
    )
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard Self.directCallsEnabled else {
      return
    }
    let deviceToken = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard Self.directCallsEnabled else {
      return
    }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard Self.directCallsEnabled else {
      completion()
      return
    }
    guard type == .voIP else {
      completion()
      return
    }

    let payloadMap = payload.dictionaryPayload
    let eventName = (payloadMap["event"] as? String ?? "incoming").lowercased()
    let callId =
      (payloadMap["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (payloadMap["callId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? UUID().uuidString

    if eventName == "cancel" || eventName == "end" {
      let data = flutter_callkit_incoming.Data(
        id: callId,
        nameCaller: "Talkflix",
        handle: "Talkflix",
        type: 0
      )
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(data)
      completion()
      return
    }

    let callerName =
      (payloadMap["nameCaller"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Talkflix"
    let handle =
      (payloadMap["handle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Talkflix"
    let isVideo =
      (payloadMap["isVideo"] as? String == "1")
      || (payloadMap["isVideo"] as? Bool == true)
      || (payloadMap["video"] as? Bool == true)
    let avatar =
      (payloadMap["avatar"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let threadId =
      (payloadMap["threadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let fromUserId =
      (payloadMap["fromUserId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""

    let data = flutter_callkit_incoming.Data(
      id: callId,
      nameCaller: callerName,
      handle: handle,
      type: isVideo ? 1 : 0
    )
    data.appName = "Talkflix"
    data.avatar = avatar
    data.iconName = "CallKitLogo"
    data.handleType = "generic"
    data.supportsVideo = isVideo
    data.extra = [
      "callId": callId,
      "threadId": threadId,
      "fromUserId": fromUserId,
      "video": isVideo,
    ]

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
      data,
      fromPushKit: true
    ) {
      completion()
    }
  }
}
