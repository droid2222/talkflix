import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private var didStart = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStart else { return }
    didStart = true
    view.backgroundColor = .systemBackground
    collectSharedText { [weak self] text in
      DispatchQueue.main.async {
        self?.openTalkflix(with: text)
      }
    }
  }

  private func collectSharedText(completion: @escaping (String?) -> Void) {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      completion(nil)
      return
    }

    let providers = items.flatMap { $0.attachments ?? [] }
    if providers.isEmpty {
      completion(nil)
      return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var result: String?

    func capture(_ value: String?) {
      let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      lock.lock()
      if result == nil {
        result = trimmed
      }
      lock.unlock()
    }

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          if let url = item as? URL {
            capture(url.absoluteString)
          } else if let string = item as? String {
            capture(string)
          }
          group.leave()
        }
      }

      if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          if let string = item as? String {
            capture(string)
          } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            capture(string)
          }
          group.leave()
        }
      }
    }

    group.notify(queue: .main) {
      completion(result)
    }
  }

  private func openTalkflix(with text: String?) {
    guard
      let text,
      let encoded = text.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed),
      let url = URL(string: "talkflix://app/app/talk?share=\(encoded)")
    else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }

    extensionContext?.open(url) { [weak self] _ in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }

  private static let queryAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return allowed
  }()
}
