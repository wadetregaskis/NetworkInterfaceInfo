import FoundationExtensions
import XCTest
import NetworkInterfaceInfo
@testable import NetworkInterfaceChangeMonitoring

final class NetworkInterfaceChangeMonitoringTests: XCTestCase {
    func testInProduction🤪() async throws {
        // Note that this never terminates - you'll have to kill the test manually when you're done.
        for try await change in NetworkInterface.changes {
            print("""
                  \(change.interface.name) \(change.nature):
                      Address: \(change.interface.address.orNilString) (\((change.interface.address?.family).orNilString))
                      Netmask: \(change.interface.netmask.orNilString)
                      Broadcast: \(change.interface.broadcastAddress.orNilString)
                      Destination: \(change.interface.destinationAddress.orNilString)
                      Flags: \(change.interface.flags)
                  """)
        }
    }
}
