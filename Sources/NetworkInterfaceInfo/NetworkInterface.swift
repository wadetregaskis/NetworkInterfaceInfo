#if canImport(Darwin)
import Darwin
#else
import Glibc

public typealias errno_t = Int32
#endif

import Foundation
import FoundationExtensions

/// Represents a specific way of accessing a network.
///
/// This is more specific than just a hardware interface - it's also tied to the address(es) used on that interface.  Thus when enumerating all the available network interfaces, you may see multiple entries for a single hardware interface (e.g. en0), one for each address on that hardware interface.
///
/// As a design note, the API would be more elegant if it were normalised; if there were one NetworkInterface for each hardware interface, with all its addresses listed as children.  However, this library is designed for efficiency when enumerating the interfaces, since many use-cases are interested in only a subset of the NetworkInterfaces, or even just a single NetworkInterface.  Given how the data is retrieved from the operating system - as a denormalised list - it is practically impossible to normalise it while also avoiding upfront work.  Users that really do prefer a normalised form can pretty easily approximate it using e.g.:
///
/// ```swift
/// Dictionary(grouping: NetworkInterface.all, by: \.name)
/// ```
public struct NetworkInterface {
    private let ifaddr: UnsafeMutablePointer<ifaddrs>
    private let lifehook: Lifehook
    
    /// The name of the logical network interface, which may be a physical network interface (e.g. en0 representing an ethernet or wifi interface) or a virtual network interface (e.g. lo0 representing a network purely for communication within the local host).
    ///
    /// You may encounter multiple `NetworkInterface` instances with the same ``name`` when enumerating all the available interfaces (e.g. with ``all``.  Each will have a different ``address``, however.
    public var name: String {
        String(cString: ifaddr.pointee.ifa_name)
    }
    
    /// A network address of the host on this interface.  e.g. 127.0.0.1 or ::1 on lo0, or 192.168.0.7 on a home network.
    public var address: NetworkAddress? {
        guard let addr = ifaddr.pointee.ifa_addr else { return nil }
        return NetworkAddress(addr: addr)
    }
    
    /// The network mask that goes along with ``address`` where applicable (e.g. for IPv4 and IPv6 addresses, but not link-layer addresses).
    ///
    /// Not always present, even where it does logically apply - typically that implies the interface in question is not actually active (contrary to what ``up`` or ``running`` might suggest).
    public var netmask: NetworkAddress? {
        guard let mask = ifaddr.pointee.ifa_netmask else { return nil }
        
#if canImport(Darwin) // Linux's sockaddr doesn't have a length field (sa_len).
        guard 0 < mask.pointee.sa_len else { return nil }
        let realSize = (AF_INET == ifaddr.pointee.ifa_netmask.pointee.sa_family) ? 8 : nil // As of macOS 13.3.1 (and presumably earlier) getifaddrs does some weird shit regarding sockaddr_in, truncating it to eight bytes for netmasks, sometimes.  https://blog.wadetregaskis.com/getifaddrs-returns-truncated-sockaddr_ins-for-af_inet-ifa_netmasks
#else
        let realSize: Int? = nil
#endif

        return NetworkAddress(addr: mask, realSize: realSize)
    }
    
    /// The broadcast address for the network, where applicable (mainly just IPv4 networks).  Traffic sent to this address is nominally received by all devices on the network (but only the immediate network - broadcast traffic is not generally routed across network boundaries).
    public var broadcastAddress: NetworkAddress? {
        guard flags.contains(.broadcastAvailable) else { return nil }
        
#if canImport(Darwin)
        // Use of ifa_dstaddr is correct, not a typo.  On Apple platforms this field serves double-duty (implying that IFF_BROADCAST is mutually exclusive to IFF_POINTTOPOINT, though nothing in the ifaddrs design enforces this).  See the man page for getifaddrs.
        if let addr = ifaddr.pointee.ifa_dstaddr, 0 < addr.pointee.sa_len {
            return NetworkAddress(addr: addr)
        } else {
            // Workaround for getifaddrs bug whereby it never specifies broadcast addresses.  https://blog.wadetregaskis.com/getifaddrs-never-specifies-broadcast-addresses
            guard let addr = address?.IPv4?.address,
                  let mask = netmask?.IPv4?.address else { return nil }
            
            let broadcastAddr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                            sin_family: sa_family_t(AF_INET),
                                            sin_port: 0,
                                            sin_addr: in_addr(s_addr: addr | ~mask),
                                            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            
            return withUnsafePointer(to: broadcastAddr) {
                NetworkAddress(addr: UnsafeRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1))
            }
        }
#else
        guard let addr = ifaddr.pointee.ifa_ifu.ifu_broadaddr else {
            return nil
        }

        return NetworkAddress(addr: addr)
#endif
    }
    
    /// The address of the other side of a point-to-point link.  Only applies to point-to-point links (as per ``pointToPoint``.
    public var destinationAddress: NetworkAddress? {
        guard flags.contains(.pointToPoint) else { return nil }

#if canImport(Darwin)
        guard let addr = ifaddr.pointee.ifa_dstaddr, 0 < addr.pointee.sa_len else { // Sometimes Apple's getifaddrs returns ifa_dstaddr's that are invalid; sa_len & sa_family are zero.  e.g. for utunN interfaces.
            return nil
        }
#else
        guard let addr = ifaddr.pointee.ifa_ifu.ifu_dstaddr else {
            return nil
        }
#endif

        return NetworkAddress(addr: addr)
    }

    /// Returns the address family used on this interface.
    ///
    /// This may be nil in two scenarios:
    ///  1. There are no addresses of any kind on this interface, so the address family is undefined.
    ///  2. Addresses disagree on what family they belong to (e.g. ``address`` is IPv4 yet ``netmask`` is IPv6).
    ///
    /// Both situations are theoretically impossible but technically could occur if there's a bug somewhere (whether in this package, the OS libraries, or the OS kernel).  You can force-unwrap the optional result if you really want, but consider if you can just gloss over it if it's nil, rather than crashing.
    public var addressFamily: NetworkAddress.AddressFamily? {
        let families = Set([address?.family, netmask?.family, destinationAddress?.family, broadcastAddress?.family])

        guard let family = families.first, 1 == families.count else {
            return nil
        }

        return family
    }

    /// Flags for the interface, as an `OptionSet`.  You can also use the boolean convenience properties, e.g. ``up``, ``loopback``, etc, if you prefer.
    public var flags: Flags {
        Flags(rawValue: ifaddr.pointee.ifa_flags)
    }
    
    /// Flags catagorising the behaviour, status, and configuration of the interface.
    ///
    /// These correspond to the `IFF_*` flags in `/usr/include/net/if.h`.  Many of these are found across all \*nix systems - you can find a lot of information online about what specifically each one means.  The meaning & purpose of many of them is esoteric and not of interest to most users - the most commonly noted ones are ``up`` (is the interface actually operating & connected to the network) and ``loopback`` (does the interface operate only on the current host, not actually out onto a shared network).
    public struct Flags: OptionSet {
        public let rawValue: UInt32
        
        // Only defined explicitly because of a bug in Swift (https://github.com/apple/swift/issues/58521).
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        public static let up = Flags(rawValue: UInt32(IFF_UP))
        public static let broadcastAvailable = Flags(rawValue: UInt32(IFF_BROADCAST))
        public static let debug = Flags(rawValue: UInt32(IFF_DEBUG))
        public static let loopback = Flags(rawValue: UInt32(IFF_LOOPBACK))
        public static let pointToPoint = Flags(rawValue: UInt32(IFF_POINTOPOINT))
        public static let noTrailers = Flags(rawValue: UInt32(IFF_NOTRAILERS))
        public static let running = Flags(rawValue: UInt32(IFF_RUNNING))
        public static let noARP = Flags(rawValue: UInt32(IFF_NOARP))
        public static let promiscuous = Flags(rawValue: UInt32(IFF_PROMISC))
        public static let receivesAllMulticastPackets = Flags(rawValue: UInt32(IFF_ALLMULTI))

#if canImport(Darwin)
        public static let transmissionInProgress = Flags(rawValue: UInt32(IFF_OACTIVE))
        public static let simplex = Flags(rawValue: UInt32(IFF_SIMPLEX))
        public static let link0 = Flags(rawValue: UInt32(IFF_LINK0))
        public static let link1 = Flags(rawValue: UInt32(IFF_LINK1))
        public static let link2 = Flags(rawValue: UInt32(IFF_LINK2))
        public static let usesAlternatePhysicalConnection = Flags(rawValue: UInt32(IFF_ALTPHYS))
#else
        public static let master = Flags(rawValue: UInt32(IFF_MASTER))
        public static let slave = Flags(rawValue: UInt32(IFF_SLAVE))
        public static let portSelectionAvailable = Flags(rawValue: UInt32(IFF_PORTSEL))
        public static let autoMediaSelection = Flags(rawValue: UInt32(IFF_AUTOMEDIA))
        public static let `dynamic` = Flags(rawValue: UInt32(IFF_DYNAMIC))
#endif

        public static let supportsMulticast: NetworkInterface.Flags = Flags(rawValue: UInt32(IFF_MULTICAST))
    }
    
    public var up: Bool { flags.contains(.up) }
    public var broadcastAvailable: Bool { flags.contains(.broadcastAvailable) }
    public var debug: Bool { flags.contains(.debug) }
    public var loopback: Bool { flags.contains(.loopback) }
    public var pointToPoint: Bool { flags.contains(.pointToPoint) }
    public var noTrailers: Bool { flags.contains(.noTrailers) }
    public var running: Bool { flags.contains(.running) }
    public var noARP: Bool { flags.contains(.noARP) }
    public var promiscuous: Bool { flags.contains(.promiscuous) }
    public var receivesAllMulticastPackets: Bool { flags.contains(.receivesAllMulticastPackets) }

#if canImport(Darwin)
    public var transmissionInProgress: Bool { flags.contains(.transmissionInProgress) }
    public var simplex: Bool { flags.contains(.simplex) }
    public var link0: Bool { flags.contains(.link0) }
    public var link1: Bool { flags.contains(.link1) }
    public var link2: Bool { flags.contains(.link2) }
    public var usesAlternatePhysicalConnection: Bool { flags.contains(.usesAlternatePhysicalConnection) }
#else
    public var master: Bool { flags.contains(.master) }
    public var slave: Bool { flags.contains(.slave) }
    public var portSelectionAvailable: Bool { flags.contains(.portSelectionAvailable) }
    public var autoMediaSelection: Bool { flags.contains(.autoMediaSelection) }
    public var `dynamic`: Bool { flags.contains(.`dynamic`) }
#endif

    public var supportsMulticast: Bool { flags.contains(.supportsMulticast) }
    
    /// Keeps the underlying data structures, as returned by getifaddrs, alive as long as any NetworkInterfaces are using them.
    private final class Lifehook {
        private let head: UnsafeMutablePointer<ifaddrs>
        
        init(_ ptr: UnsafeMutablePointer<ifaddrs>) {
            head = ptr
        }
        
        deinit {
            freeifaddrs(head)
        }
    }
    
    /// All the network interfaces (as of the time it is accessed).
    ///
    /// This is the primary intended way of using this library.
    ///
    /// Creating and returning this collection is relatively lightweight - mostly just the cost of the system call to fetch the raw data.  The details of each ``NetworkInterface`` are only decoded from that raw data if & when they're used (through the properties on ``NetworkInterface``).  This is very intentional, and helps ensure this API is efficient for common cases like enumerating the interfaces just to find those that are active, or those that are up, or corresponding to a specific IP address.
    ///
    /// On the flip side, be aware that the memory used to store all the interface information is only freed once there are no more copies of _any_ of the ``NetworkInterface`` instances in the returned collection.  While the amount of memory in question is pretty small, avoid keeping ``NetworkInterface`` instances around for long durations unless you actually need them.
    ///
    /// Note that ``NetworkAddress`` instances are truly standalone and do not cause any memory to be retained other than what they directly need (which is usually very little - on the order of tens of bytes).
    public static var all: [NetworkInterface] {
        get throws {
            var ifHead: UnsafeMutablePointer<ifaddrs>? = nil
            
            guard 0 == getifaddrs(&ifHead) else {
                throw Errors.getifaddrsFailed(errno: errno)
            }
            
            guard let ifHead else {
                return []
            }
            
            let lifehook = Lifehook(ifHead)
            
            return sequence(first: ifHead, next: { $0.pointee.ifa_next }).map {
                NetworkInterface(ifaddr: $0, lifehook: lifehook)
            }
        }
    }
        
    public enum Errors: Error {
        /// The low-level OS-library function that retrieves all the information from the kernel, getifaddrs, failed with the given 'explanation' by way of an error number.  These error codes are defined in `/usr/include/sys/errno.h` (and exposed to Swift through the ``Darwin`` or ``Glibc`` modules), as e.g. ``Darwin/ENOMEM``.
        case getifaddrsFailed(errno: errno_t)
    }
}

extension NetworkInterface: Equatable {
    public static func == (lhs: NetworkInterface, rhs: NetworkInterface) -> Bool {
        (lhs.address == rhs.address
         && lhs.netmask == rhs.netmask
         && lhs.broadcastAddress == rhs.broadcastAddress
         && lhs.destinationAddress == rhs.destinationAddress
         && lhs.flags == rhs.flags)
    }
}

extension NetworkInterface: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(address)
        hasher.combine(netmask)
        hasher.combine(broadcastAddress)
        hasher.combine(destinationAddress)
        hasher.combine(flags)
    }
}

extension NetworkInterface: CustomStringConvertible {
    public var description: String {
        let address = address
        let netmask = netmask
        let broadcastAddress = broadcastAddress
        let destinationAddress = destinationAddress

        return ("Network interface(name: \(name)"
                + (nil != address ? ", address: \(address!)" : "")
                + (nil != netmask ? ", netmask: \(netmask!)" : "")
                + (nil != broadcastAddress ? ", broadcast address: \(broadcastAddress!)" : "")
                + (nil != destinationAddress ? ", broadcast address: \(destinationAddress!)" : "")
                + ", flags: [\(flags)])")
    }
}

extension NetworkInterface.Flags: CaseIterable {
#if canImport(Darwin)
    public static let allCases: [Self] = [.up,
                                          .broadcastAvailable,
                                          .debug,
                                          .loopback,
                                          .pointToPoint,
                                          .noTrailers,
                                          .running,
                                          .noARP,
                                          .promiscuous,
                                          .receivesAllMulticastPackets,
                                          .transmissionInProgress,
                                          .simplex,
                                          .link0,
                                          .link1,
                                          .link2,
                                          .usesAlternatePhysicalConnection,
                                          .supportsMulticast]
#else
    public static let allCases: [Self] = [.up,
                                          .broadcastAvailable,
                                          .debug,
                                          .loopback,
                                          .pointToPoint,
                                          .noTrailers,
                                          .running,
                                          .noARP,
                                          .promiscuous,
                                          .receivesAllMulticastPackets,
                                          .master,
                                          .slave,
                                          .portSelectionAvailable,
                                          .autoMediaSelection,
                                          .`dynamic`,
                                          .supportsMulticast]
#endif
}

extension NetworkInterface.Flags: Hashable {}

extension NetworkInterface.Flags: CustomStringConvertible {
#if canImport(Darwin)
    private static let names = [Self: String]([(.up, "Up"),
                                               (.broadcastAvailable, "Broadcast available"),
                                               (.debug, "Debug"),
                                               (.loopback, "Loopback"),
                                               (.pointToPoint, "Point to point"),
                                               (.noTrailers, "No trailers"),
                                               (.running, "Running"),
                                               (.noARP, "No ARP"),
                                               (.promiscuous, "Promiscuous"),
                                               (.receivesAllMulticastPackets, "Receives all multicast packets"),
                                               (.transmissionInProgress, "Transmission in progress"),
                                               (.simplex, "Simplex"),
                                               (.link0, "Link 0"),
                                               (.link1, "Link 1"),
                                               (.link2, "Link 2"),
                                               (.usesAlternatePhysicalConnection, "Uses alternate physical connection"),
                                               (.supportsMulticast, "Supports multicast")]) { $1 }
#else
    private static let names = [Self: String]([(.up, "Up"),
                                               (.broadcastAvailable, "Broadcast available"),
                                               (.debug, "Debug"),
                                               (.loopback, "Loopback"),
                                               (.pointToPoint, "Point to point"),
                                               (.noTrailers, "No trailers"),
                                               (.running, "Running"),
                                               (.noARP, "No ARP"),
                                               (.promiscuous, "Promiscuous"),
                                               (.receivesAllMulticastPackets, "Receives all multicast packets"),
                                               (.master, "Master"),
                                               (.slave, "Slave"),
                                               (.portSelectionAvailable, "Port selection available"),
                                               (.autoMediaSelection, "Auto media selection"),
                                               (.`dynamic`, "Loses address when down"),
                                               (.supportsMulticast, "Supports multicast")]) { $1 }
#endif
    
    public var description: String {
        let knownFlagBits = Self.allCases.filter { self.contains($0) }
        
        return (Set(knownFlagBits.map { Self.names[$0] ?? "Unknown" }).sorted()
                + self.subtracting(Self(knownFlagBits)).rawValue.bits.map { "0x" + String($0, radix: 16) })
                .joined(separator: ", ")
    }
}
