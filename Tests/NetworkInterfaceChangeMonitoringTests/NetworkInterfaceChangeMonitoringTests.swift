import FoundationExtensions
import XCTest
import NetworkInterfaceInfo
@testable import NetworkInterfaceChangeMonitoring

final class NetworkInterfaceChangeMonitoringTests: XCTestCase {
    func testInProduction🤪() async throws {
        let task = Task {
            for try await change in NetworkInterface.changes {
                let changedFields: NetworkInterface.Change.ModificationNature

                switch change.nature {
                case .modified(let modificationNature):
                    changedFields = modificationNature
                default:
                    changedFields = []
                }

                print("""
                      \(change.interface.name) \(change.nature):
                       \(changedFields.contains(.address) ? "🔔" : "  ") Address: \(change.interface.address.orNilString) (\((change.interface.address?.family).orNilString))
                       \(changedFields.contains(.netmask) ? "🔔" : "  ") Netmask: \(change.interface.netmask.orNilString)
                       \(changedFields.contains(.broadcastAddress) ? "🔔" : "  ") Broadcast: \(change.interface.broadcastAddress.orNilString)
                       \(changedFields.contains(.destinationAddress) ? "🔔" : "  ") Destination: \(change.interface.destinationAddress.orNilString)
                       \(changedFields.contains(.flags) ? "🔔" : "  ") Flags: \(change.interface.flags)
                      """)
            }
        }

        // This is really just so that automated tests (e.g. on GitHub) don't run forever.  Best to add a bunch more zeroes to it when actually using it locally.
        try await Task.sleep(nanoseconds: 60_000_000_000)
        task.cancel()
    }
}
