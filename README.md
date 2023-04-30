# NetworkInterfaceInfo

[![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/wadetregaskis/NetworkInterfaceInfo.svg)]()
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fwadetregaskis%2FNetworkInterfaceInfo%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/wadetregaskis/NetworkInterfaceInfo)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fwadetregaskis%2FNetworkInterfaceInfo%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/wadetregaskis/NetworkInterfaceInfo)
[![GitHub build results](https://github.com/wadetregaskis/NetworkInterfaceInfo/actions/workflows/swift.yml/badge.svg)](https://github.com/wadetregaskis/NetworkInterfaceInfo/actions/workflows/swift.yml)

Basically a Swift abstraction over `getifaddrs`; a way to enumerate all the network interfaces on the current host, with their core information such as associated addresses & netmasks.

This is intentionally very lightweight, and designed to be very efficient even for cases where you're looking for a small subset of interfaces.  e.g. to find all active IPv4 addresses (excluding loopback networks):

```swift
import NetworkInterfaceInfo

try NetworkInterface.all
    .filter { $0.up             // Only active network interfaces…
              && !$0.loopback } // Ignoring loopback interfaces…
    .compactMap(\.address)      // That have addresses and…
    .filter(\.isIPv4)           // Use IPv4.
```

There is also a second module which allows you to monitor for changes to network interfaces, e.g.:

```swift
import NetworkInterfaceInfo
import NetworkInterfaceChangeMonitoring

for try await change in NetworkInterface.changes() {
    switch change.nature {
    case .added:
        print("New network interface: \(change.interface)")
    case .modified(let modificationNature):
        if modificationNature.contains(.address) {
            print("Address changed to \(change.interface.address).")
        }
    case .removed:
        // etc
    }
}
```

Note that you still need to explicitly `import NetworkInterfaceInfo` in order to access the `changes` property and otherwise use `NetworkInterface` et al.

This monitoring functionality is in a separate module so that you don't pay the cost of it if you don't need it.

Important:  monitoring for network interface changes relies on Apple's Network framework, specifically NWPathMonitor.  Generally that notices changes virtually immediately, but sometimes it is delayed - up to minute(s) later.  This might be worked around in a future version of this library, but for now at least be aware of that annoying uncertainty and consider taking steps to work around it (e.g. polling `NetworkInterface.all` instead, if you need a clear latency upper bound).
