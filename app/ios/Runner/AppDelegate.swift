import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cover: UIView?
  private var channel: FlutterMethodChannel?
  private var clock: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let nc = NotificationCenter.default
    // Segundo plano: cobre a tela (miniatura do seletor de apps).
    nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.showCover()
    }
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.updateCover()
    }
    // Gravação ou espelhamento de tela: esconde o conteúdo enquanto durar.
    nc.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.updateCover()
    }
    // Print: o iOS não deixa bloquear; só avisa depois que já foi tirado.
    nc.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
      self?.channel?.invokeMethod("screenshot", arguments: nil)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Recusa teclado de terceiros (ameacas.md §7): com "acesso total" ele
  /// registraria tudo, inclusive a senha do app.
  override func application(
    _ application: UIApplication,
    shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
  ) -> Bool {
    extensionPointIdentifier != .keyboard
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "DirectScreenGuard")?.messenger() {
      channel = FlutterMethodChannel(name: "direct/screen", binaryMessenger: messenger)
      clock = FlutterMethodChannel(name: "direct/clock", binaryMessenger: messenger)
      clock?.setMethodCallHandler { call, result in
        if call.method == "uptime" {
          result(Int(ProcessInfo.processInfo.systemUptime * 1000))
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func showCover() {
    guard cover == nil, let window = keyWindow() else { return }
    let v = UIView(frame: window.bounds)
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    v.backgroundColor = .systemBackground
    let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
    icon.tintColor = .secondaryLabel
    icon.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 56),
      icon.heightAnchor.constraint(equalToConstant: 56),
    ])
    window.addSubview(v)
    cover = v
  }

  private func hideCover() {
    cover?.removeFromSuperview()
    cover = nil
  }

  /// Cobertura fica enquanto a tela estiver sendo gravada ou espelhada.
  private func updateCover() {
    if UIScreen.main.isCaptured { showCover() } else { hideCover() }
  }
}
