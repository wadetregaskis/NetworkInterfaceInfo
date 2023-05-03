import FoundationExtensions
import XCTest
@testable import NetworkInterfaceInfo

final class NetworkInterfaceInfoTests: XCTestCase {
    func testInProduction🤪() throws {
        for interface in try NetworkInterface.all {
#if canImport(Darwin) && !os(iOS) && !os(watchOS) && !os(tvOS)
            print("""
                  \(interface.name):
                      Address: \(interface.address.orNilString) (\((interface.address?.family).orNilString))
                      Netmask: \(interface.netmask.orNilString)
                      Broadcast: \(interface.broadcastAddress.orNilString)
                      Destination: \(interface.destinationAddress.orNilString)
                      Flags: \(interface.flags)
                      Metrics: \(try interface.metrics)
                  """)
#else
            print("""
                  \(interface.name):
                      Address: \(interface.address.orNilString) (\((interface.address?.family).orNilString))
                      Netmask: \(interface.netmask.orNilString)
                      Broadcast: \(interface.broadcastAddress.orNilString)
                      Destination: \(interface.destinationAddress.orNilString)
                      Flags: \(interface.flags)
                  """)
#endif
        }
    }
}
