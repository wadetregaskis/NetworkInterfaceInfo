# NetworkInterfaceInfo

![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/wadetregaskis/NetworkInterfaceInfo.svg)
![GitHub build results](https://github.com/wadetregaskis/NetworkInterfaceInfo/actions/workflows/swift.yml/badge.svg)

Basically a Swift abstraction over `getifaddrs`; a way to enumerate all the network interfaces on the current host, with their core information such as associated addresses & netmasks.

This is intentionally very lightweight, and designed to be very efficient even for cases where you're looking for a small subset of interfaces.  e.g. to find all active IPv4 addresses (excluding loopback networks):

```
try NetworkInterface.all
    .filter { $0.up             // Only active network interfaces…
              && !$0.loopback } // Ignoring loopback interfaces…
    .compactMap(\.address)      // That have addresses and…
    .filter(\.isIPv4)           // Use IPv4.
```
