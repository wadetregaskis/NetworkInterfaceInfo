#if !canImport(Network)
#warning("NetworkInterfaceChangeMonitoring requires the Network module, which is not available (it is a propertiary Apple module only available on Apple platforms, not Linux or Windows).")
#else

import FoundationExtensions
import XCTest
import NetworkInterfaceInfo
@testable import NetworkInterfaceChangeMonitoring

final class NetworkInterfaceChangeMonitoringTests: XCTestCase {
    func testInProduction🤪() async throws {
        let task = Task {
            for try await change in NetworkInterface.changes(coalescingPeriod: 5) {
                let changedFields: NetworkInterface.Change.ModificationNature

                switch change.nature {
                case .modified(let modificationNature):
                    changedFields = modificationNature
                default:
                    changedFields = []
                }

                func markIf(_ field: NetworkInterface.Change.ModificationNature) -> String {
                    changedFields.contains(field) ? "🔔" : "  "
                }

                print("""
                      \(change.interface.name) \(change.nature):
                       \(markIf(.address)) Address: \(change.interface.address.orNilString) (\((change.interface.address?.family).orNilString))
                       \(markIf(.netmask)) Netmask: \(change.interface.netmask.orNilString)
                       \(markIf(.broadcastAddress)) Broadcast: \(change.interface.broadcastAddress.orNilString)
                       \(markIf(.destinationAddress)) Destination: \(change.interface.destinationAddress.orNilString)
                       \(markIf(.flags)) Flags: \(change.interface.flags)
                      """)
            }
        }

        // This is really just so that automated tests (e.g. on GitHub) don't run forever.  Best to add a bunch more zeroes to it when actually using it locally.
        try await Task.sleep(nanoseconds: 60_000_000_000)
        task.cancel()
    }
}
#endif