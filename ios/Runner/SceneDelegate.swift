import Flutter
import UIKit

final class SceneDelegate: FlutterSceneDelegate {
  private var pendingRoute: String?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    if let urlContext = connectionOptions.urlContexts.first,
       routeIncomingURL(urlContext.url) {
      return
    }

    if let activity = connectionOptions.userActivities.first,
       routeIncomingUserActivity(activity) {
      return
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let urlContext = URLContexts.first, routeIncomingURL(urlContext.url) {
      return
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if routeIncomingUserActivity(userActivity) {
      return
    }
    super.scene(scene, continue: userActivity)
  }

  private func routeIncomingUserActivity(_ userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else {
      return false
    }
    return routeIncomingURL(url)
  }

  private func routeIncomingURL(_ url: URL) -> Bool {
    guard let route = Self.routeForIncomingURL(url) else {
      return false
    }
    pendingRoute = route
    DispatchQueue.main.async { [weak self] in
      self?.dispatchPendingRoute()
    }
    return true
  }

  private func dispatchPendingRoute() {
    guard let route = pendingRoute else {
      return
    }
    guard let flutterViewController = window?.rootViewController as? FlutterViewController else {
      DispatchQueue.main.async { [weak self] in
        self?.dispatchPendingRoute()
      }
      return
    }
    flutterViewController.pushRoute(route)
    pendingRoute = nil
  }

  private static func routeForIncomingURL(_ url: URL) -> String? {
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
        shareText.addingPercentEncoding(withAllowedCharacters: routeQueryAllowed)
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
}
