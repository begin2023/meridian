import Foundation
import PrivilegedSupport

enum HelperInstallStatus: Equatable { case notRegistered, enabled, requiresApproval, notSupported }
final class DaemonInstaller {
    static let daemonLabel = "app.meridian.thermal.daemon"
    private var installer: HelperInstallation { HelperInstallation(label: Self.daemonLabel, bundledRelativePath: "Contents/Library/LaunchServices/\(Self.daemonLabel)") }
    var status: HelperInstallStatus { installer.isInstalled ? .enabled : .notRegistered }
    var needsUpdate: Bool { installer.needsUpdate }
    func install() throws { try installer.install() }
    func uninstall() throws { try installer.uninstall() }
}
