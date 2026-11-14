//
// LensHost.swift
//
// The lens is one web page (the lens folder, shared with the Mac and the glasses' own browser).
// Here it runs in a web view, in one of two ways:
//
//   on the phone   the page holds the whole brain. Its model requests come to this class,
//                  which adds the key and sends them, so the page never sees the key.
//   on the Mac     the page is loaded from the Mac, which does the thinking. The phone only
//                  passes on what it hears.
//
// Either way the app talks to the page through `call(...)`, and the page reports back with
// messages: a new frame is drawn, a look is wanted, the day's plan is ready.
//

import Foundation
import Network
import UIKit
import WebKit

@MainActor
final class LensHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let webView: WKWebView

  /// The page is up. The argument says where the thinking happens: "phone" or "mac".
  var onReady: ((String) -> Void)?
  /// A new frame was drawn. Carries the phase, the headline and a plain-text version.
  var onState: (([String: Any]) -> Void)?
  /// The brain wants to see what the wearer is looking at.
  var onLook: (() -> Void)?
  /// The rest of today, each event with what to have ready.
  var onPlan: (([[String: Any]]) -> Void)?
  /// The recaps kept from earlier conversations.
  var onMemory: (([[String: Any]]) -> Void)?
  /// The page could not be loaded or reached.
  var onTrouble: ((String) -> Void)?
  /// A model answer arrived. Says which way it came: 0 the usual connection, 1 a new one, 2 mobile data.
  var onRoute: ((Int) -> Void)?
  /// When Wi-Fi goes quiet, the same request may also be tried over mobile data.
  var allowMobileData = true

  /// The Meta Model API key, when it is kept on this phone.
  var apiKey = ""
  /// The linked Mac and its link code, when there is one.
  var macURL: URL?
  var macCode = ""

  private(set) var isReady = false

  private var remote: URL?
  private var waiting: [String] = []
  private var loadCount = 0
  /// The connection requests to the model normally travel on. It is replaced when it stops answering.
  private var network: URLSession
  private let modelEndpoint = URL(string: "https://api.meta.ai/v1/chat/completions")

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)

    network = LensHost.freshSession()

    super.init()

    webView.configuration.userContentController.add(self, name: "gist")
    webView.navigationDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = .black
    webView.scrollView.backgroundColor = .black
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.isUserInteractionEnabled = false
    webView.isInspectable = true
  }

  // MARK: - Loading

  /// The brain runs on this phone, from the lens files inside the app.
  func loadLocal() {
    remote = nil
    beginLoad()
    guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "lens") else {
      onTrouble?("The lens files are missing from the app. Build it again from Xcode.")
      return
    }
    webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
  }

  /// The brain runs on the Mac; this phone shows the Mac's lens and passes on what it hears.
  func loadRemote(_ base: URL, code: String) {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    var items = [URLQueryItem(name: "relay", value: "1")]
    if !code.isEmpty { items.append(URLQueryItem(name: "k", value: code)) }
    components?.queryItems = items
    if (components?.path ?? "").isEmpty { components?.path = "/" }
    guard let url = components?.url else {
      onTrouble?("That link is not a web address.")
      return
    }
    remote = url
    beginLoad()
    webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))

    // The page says "ready" after its first answer from the Mac. Silence means the link is dead.
    let mine = loadCount
    let host = base.host ?? "your Mac"
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 9_000_000_000)
      guard let self, self.loadCount == mine, !self.isReady else { return }
      self.onTrouble?("No answer from \(host). Check that “Start Gist + glasses link” is still running on the Mac, then scan code B again.")
    }
  }

  func reload() {
    if let remote {
      beginLoad()
      webView.load(URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    } else {
      loadLocal()
    }
  }

  private func beginLoad() {
    loadCount += 1
    isReady = false
    waiting = []
  }

  // MARK: - Talking to the page

  /// Calls one of the page's entry points (window.GistNative.<function>) with JSON arguments.
  func call(_ function: String, _ arguments: [Any] = []) {
    guard JSONSerialization.isValidJSONObject(arguments),
      let data = try? JSONSerialization.data(withJSONObject: arguments),
      let json = String(data: data, encoding: .utf8)
    else { return }
    let script =
      "window.GistNative && window.GistNative.\(function) && window.GistNative.\(function).apply(null, \(json)); void 0;"
    if isReady {
      webView.evaluateJavaScript(script, completionHandler: nil)
    } else if waiting.count < 60 {
      waiting.append(script)
    }
  }

  /// A square picture of the lens exactly as drawn, on black: 600 pixels a side, or fewer
  /// when the link to the glasses is slow and a lighter picture gets there sooner.
  /// Gives nil when there is no picture to be had: the lens is covered, the app is behind
  /// another one, or the page was not drawn. The caller then sends the words instead.
  func snapshot(side: Int = 600, _ completion: @escaping (UIImage?) -> Void) {
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: 0, y: 0, width: 600, height: 600)
    configuration.snapshotWidth = NSNumber(value: side)
    configuration.afterScreenUpdates = true

    // A web view that is not being drawn may never answer, so the wait is bounded.
    let once = Once()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      if once.first() { completion(nil) }
    }

    webView.takeSnapshot(with: configuration) { image, _ in
      guard once.first() else { return }
      guard let image else {
        completion(nil)
        return
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let size = CGSize(width: side, height: side)
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      let flat = renderer.image { context in
        UIColor.black.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      completion(LensHost.hasPicture(flat) ? flat : nil)
    }
  }

  /// True when something is drawn in the picture. A lens that was not painted comes back
  /// as one flat color, and a flat black frame would blank the glasses.
  nonisolated static func hasPicture(_ image: UIImage) -> Bool {
    let side = 60
    guard let source = image.cgImage,
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let data = context.data
    else { return true }
    context.interpolationQuality = .low
    context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
    var darkest = 255
    var brightest = 0
    for index in stride(from: 0, to: side * side * 4, by: 4) {
      let level = max(Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
      darkest = min(darkest, level)
      brightest = max(brightest, level)
    }
    return brightest - darkest > 20
  }

  // MARK: - Messages from the page

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "net":
      let id = body["id"] as? Int ?? 0
      let payload = body["body"] as? String ?? ""
      sendToModel(id: id, payload: payload)
    case "state":
      onState?(body)
    case "look":
      onLook?()
    case "plan":
      onPlan?(body["events"] as? [[String: Any]] ?? [])
    case "memory":
      onMemory?(body["items"] as? [[String: Any]] ?? [])
    case "ready":
      isReady = true
      let queued = waiting
      waiting = []
      for script in queued {
        webView.evaluateJavaScript(script, completionHandler: nil)
      }
      onReady?(body["brain"] as? String ?? "phone")
    default:
      break
    }
  }

  // MARK: - Model requests (the key never enters the page)

  private func sendToModel(id: Int, payload: String) {
    var request: URLRequest
    var throughMac = false
    if !apiKey.isEmpty, let modelEndpoint {
      request = URLRequest(url: modelEndpoint)
      request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
    } else if let macURL {
      var components = URLComponents(url: macURL.appendingPathComponent("model"), resolvingAgainstBaseURL: false)
      if !macCode.isEmpty { components?.queryItems = [URLQueryItem(name: "k", value: macCode)] }
      guard let url = components?.url else {
        answer(id: id, status: 0, text: "The link to the Mac is not a web address.")
        return
      }
      request = URLRequest(url: url)
      throughMac = true
    } else {
      answer(id: id, status: 0, text: "No model key yet. Add your Meta Model API key in Settings, or scan code B on the Mac’s setup page.")
      return
    }
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload.data(using: .utf8)

    let viaMac = throughMac
    let outgoing = request
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let (data, response, route) = try await self.fetch(outgoing)
        if route != 0 {
          // The usual connection had gone quiet: later requests start on a new one.
          self.network.invalidateAndCancel()
          self.network = LensHost.freshSession()
        }
        self.onRoute?(route)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = String(data: data, encoding: .utf8) ?? ""
        // The Mac wraps the model's answer as {status, text}.
        if viaMac, status == 200,
          let object = try? JSONSerialization.jsonObject(with: data),
          let wrapped = object as? [String: Any]
        {
          status = wrapped["status"] as? Int ?? 0
          text = wrapped["text"] as? String ?? ""
        }
        self.answer(id: id, status: status, text: text)
      } catch {
        self.answer(id: id, status: 0, text: error.localizedDescription)
      }
    }
  }

  /// Sends one tiny question to the model over mobile data only, and says how it went.
  /// For checking the fallback before it is needed.
  func tryMobileData() async -> String {
    guard !apiKey.isEmpty, let modelEndpoint else {
      return "This check needs the model key on this iPhone (Settings, Brain)."
    }
    var request = URLRequest(url: modelEndpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let question: [String: Any] = [
      "model": "muse-ember-1.0",
      "reasoning_effort": "low",
      "max_tokens": 200,
      "messages": [["role": "user", "content": "Reply with the single word: ready"]],
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: question)
    guard let call = MobileDataCall(request) else { return "Could not set up the request." }
    let began = Date()
    do {
      let (status, data) = try await call.run()
      let took = Date().timeIntervalSince(began)
      if status == 200 {
        return String(format: "Mobile data works: the model answered in %.1f s.", took)
      }
      let text = String(data: data.prefix(160), encoding: .utf8) ?? ""
      return "Mobile data reached the model, but it answered \(status). \(text)"
    } catch {
      return "No answer over mobile data (\(error.localizedDescription)). Check that mobile data is on for Aside."
    }
  }

  nonisolated static func freshSession() -> URLSession {
    let settings = URLSessionConfiguration.ephemeral
    settings.timeoutIntervalForRequest = 20
    settings.waitsForConnectivity = false
    return URLSession(configuration: settings)
  }

  /// Sends one request, and takes whichever of up to three attempts answers first:
  ///   the usual connection;
  ///   after 1.5 s of silence, the same request over mobile data, because a crowded Wi-Fi
  ///   network is the usual reason for the silence;
  ///   after 3 s, a brand-new connection on whatever network the phone prefers.
  /// The answer says which one brought it: 0 the usual connection, 1 the new one, 2 mobile data.
  private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse, Int) {
    let usual = network
    let overMobileData = allowMobileData ? MobileDataCall(request) : nil
    return try await withThrowingTaskGroup(of: (Data, URLResponse, Int).self) { group in
      group.addTask {
        let (data, response) = try await usual.data(for: request)
        return (data, response, 0)
      }
      if let overMobileData {
        group.addTask {
          try await Task.sleep(nanoseconds: 1_500_000_000)
          let (status, data) = try await overMobileData.run()
          // Only a clean answer counts from this route; anything else is left to the other two.
          guard status == 200, let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
          else { throw URLError(.badServerResponse) }
          return (data, response, 2)
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let fresh = LensHost.freshSession()
        defer { fresh.finishTasksAndInvalidate() }
        let (data, response) = try await fresh.data(for: request)
        return (data, response, 1)
      }
      var firstError: Error?
      while let result = await group.nextResult() {
        switch result {
        case .success(let answer):
          group.cancelAll()
          return answer
        case .failure(let error):
          if firstError == nil { firstError = error }
        }
      }
      throw firstError ?? URLError(.unknown)
    }
  }

  private func answer(id: Int, status: Int, text: String) {
    let payload: [Any] = [id, status, text]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return }
    webView.evaluateJavaScript("window.__gistNet && window.__gistNet.apply(null, \(json)); void 0;", completionHandler: nil)
  }

  // MARK: - Navigation

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    onTrouble?("The lens did not load: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    onTrouble?("The lens did not load: \(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    reload()
  }
}

/// Lets two competing answers (the picture, or the wait running out) settle on the first one.
private final class Once: @unchecked Sendable {
  private var used = false
  func first() -> Bool {
    if used { return false }
    used = true
    return true
  }
}

/// One HTTPS request sent over mobile data only, whatever Wi-Fi is doing. URLSession cannot be
/// told which network to use, so this speaks plain HTTP/1.1 over a Network.framework connection
/// that is only allowed to use the mobile network. With no mobile data to use, it fails at once.
final class MobileDataCall: @unchecked Sendable {
  private let connection: NWConnection
  private let message: Data
  private let queue = DispatchQueue(label: "aside.mobile-data")

  // Touched on `queue` only.
  private var received = Data()
  private var waiter: CheckedContinuation<(Int, Data), Error>?
  private var done = false

  init?(_ request: URLRequest) {
    guard let url = request.url, url.scheme == "https", let host = url.host else { return nil }
    let body = request.httpBody ?? Data()
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query, !query.isEmpty { path += "?" + query }

    var head = "\(request.httpMethod ?? "GET") \(path) HTTP/1.1\r\n"
    head += "Host: \(host)\r\n"
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      head += "\(name): \(value)\r\n"
    }
    head += "Accept: application/json\r\n"
    head += "Accept-Encoding: identity\r\n"
    head += "Connection: close\r\n"
    head += "Content-Length: \(body.count)\r\n\r\n"
    var whole = Data(head.utf8)
    whole.append(body)
    message = whole

    let parameters = NWParameters(tls: NWProtocolTLS.Options())
    parameters.requiredInterfaceType = .cellular
    let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? NWEndpoint.Port.https
    connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
  }

  /// The status code and the body of the answer.
  func run() async throws -> (Int, Data) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, Data), Error>) in
        self.queue.async {
          if self.done {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.waiter = continuation
          // `finish` clears this handler, so holding on to the call here does not keep it alive for good.
          self.connection.stateUpdateHandler = { state in
            self.changed(to: state)
          }
          self.connection.start(queue: self.queue)
          self.queue.asyncAfter(deadline: .now() + 15) {
            self.finish(.failure(URLError(.timedOut)))
          }
        }
      }
    } onCancel: {
      self.queue.async {
        self.finish(.failure(CancellationError()))
      }
    }
  }

  private func changed(to state: NWConnection.State) {
    switch state {
    case .ready:
      connection.send(
        content: message,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.finish(.failure(error))
          } else {
            self?.readMore()
          }
        })
    case .waiting(let error):
      finish(.failure(error))   // no mobile data to use right now
    case .failed(let error):
      finish(.failure(error))
    default:
      break
    }
  }

  private func readMore() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data { self.received.append(data) }
      let closed = isComplete || error != nil
      if let answer = MobileDataCall.answer(in: self.received, closed: closed) {
        self.finish(.success(answer))
      } else if let error {
        self.finish(.failure(error))
      } else if isComplete {
        self.finish(.failure(URLError(.badServerResponse)))
      } else {
        self.readMore()
      }
    }
  }

  private func finish(_ result: Result<(Int, Data), Error>) {
    guard !done else { return }
    done = true
    connection.stateUpdateHandler = nil
    connection.cancel()
    waiter?.resume(with: result)
    waiter = nil
  }

  /// The status and the body once the whole answer is in; nil while more is still to come.
  static func answer(in data: Data, closed: Bool) -> (Int, Data)? {
    guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let first = (lines.first ?? "").split(separator: " ")
    guard first.count >= 2, let status = Int(first[1]) else { return nil }
    let body = Data(data[split.upperBound...])

    var length: Int?
    var chunked = false
    for line in lines.dropFirst() {
      let lower = line.lowercased()
      if lower.hasPrefix("content-length:") {
        length = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
      } else if lower.hasPrefix("transfer-encoding:"), lower.contains("chunked") {
        chunked = true
      }
    }
    if chunked {
      guard let joined = unchunked(body) else { return nil }
      return (status, joined)
    }
    if let length {
      return body.count >= length ? (status, Data(body.prefix(length))) : nil
    }
    return closed ? (status, body) : nil
  }

  /// A chunked body put back together; nil until its last chunk has arrived.
  static func unchunked(_ data: Data) -> Data? {
    let lineEnd = Data("\r\n".utf8)
    var joined = Data()
    var index = data.startIndex
    while true {
      guard let end = data.range(of: lineEnd, in: index..<data.endIndex) else { return nil }
      let sizeText = String(decoding: data[index..<end.lowerBound], as: UTF8.self)
      let hex = sizeText.split(separator: ";").first.map(String.init) ?? ""
      guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
      let start = end.upperBound
      if size == 0 { return joined }
      guard data.endIndex - start >= size + 2 else { return nil }
      joined.append(data[start..<(start + size)])
      index = start + size + 2
    }
  }
}
