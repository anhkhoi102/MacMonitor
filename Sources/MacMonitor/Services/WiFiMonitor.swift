import CoreLocation
import CoreWLAN
import Observation

/// Name (SSID) of the connected Wi-Fi network (Network page).
///
/// ## Why Location Services is involved
/// Since macOS 14, Apple only gives an app the Wi-Fi network name if the app
/// has Location Services permission (a network name can reveal where you
/// are). So MacMonitor asks for that permission – only when you press the
/// button – and uses it for nothing else: it never requests or stores your
/// location.
///
/// CoreWLAN reads the name from the Wi-Fi hardware each time; nothing is
/// cached, so an old network is never shown as the current one.
@MainActor
@Observable
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case connected(String)
        case notConnected
        case wifiOff
        case noWiFiHardware
        case needsPermission
        case permissionDenied
        case nameHidden
    }

    private(set) var state: State = .notConnected
    @ObservationIgnored private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func refresh() {
        guard let wifi = CWWiFiClient.shared().interface() else { state = .noWiFiHardware; return }
        guard wifi.powerOn() else { state = .wifiOff; return }
        switch locationManager.authorizationStatus {
        case .notDetermined: state = .needsPermission; return
        case .denied, .restricted: state = .permissionDenied; return
        default: break
        }
        if let ssid = wifi.ssid(), !ssid.isEmpty {
            state = .connected(ssid)
        } else if wifi.wlanChannel() == nil {
            state = .notConnected
        } else {
            state = .nameHidden   // associated, but macOS withheld the name
        }
    }

    /// Shows macOS's permission prompt. Only called from a button press.
    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
