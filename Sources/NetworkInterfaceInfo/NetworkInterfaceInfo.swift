import Darwin
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
    private let ifaddr: ifaddrs
    private let lifehook: Lifehook
    
    /// The name of the logical network interface, which may be a physical network interface (e.g. en0 representing an ethernet or wifi interface) or a virtual network interface (e.g. lo0 representing a network purely for communication within the local host).
    ///
    /// You may encounter multiple `NetworkInterface` instances with the same ``name`` when enumerating all the available interfaces (e.g. with ``all``.  Each will have a different ``address``, however.
    public var name: String {
        String(cString: ifaddr.ifa_name)
    }
    
    /// A network address of the host on this interface.  e.g. 127.0.0.1 or ::1 on lo0, or 192.168.0.7 on a home network.
    public var address: NetworkAddress? {
        guard let addr = ifaddr.ifa_addr else { return nil }
        return NetworkAddress(addr: addr)
    }
    
    /// The network mask that goes along with ``address`` where applicable (e.g. for IPv4 and IPv6 addresses, but not link-layer addresses).
    ///
    /// Not always present, even where it does logically apply - typically that implies the interface in question is not actually active (contrary to what ``up`` or ``running`` might suggest).
    public var netmask: NetworkAddress? {
        guard let mask = ifaddr.ifa_netmask, 0 < mask.pointee.sa_len else { return nil }
        return NetworkAddress(addr: mask,
                              realSize: (AF_INET == ifaddr.ifa_netmask.pointee.sa_family ? 8 : nil)) // As of macOS 13.3.1 (and presumably earlier) getifaddrs does some weird shit regarding sockaddr_in, truncating it to eight bytes for netmasks, sometimes.  https://blog.wadetregaskis.com/getifaddrs-returns-truncated-sockaddr_ins-for-af_inet-ifa_netmasks
    }
    
    /// The broadcast address for the network, where applicable (mainly just IPv4 networks).  Traffic sent to this address is nominally received by all devices on the network (but only the immediate network - broadcast traffic is not generally routed across network boundaries).
    public var broadcastAddress: NetworkAddress? {
        guard flags.contains(.broadcastAvailable) else { return nil }
        
        // Use of ifa_dstaddr is correct, not a typo.  The field serves double-duty (implying that IFF_BROADCAST is mutually exclusive to IFF_POINTTOPOINT, though nothing in the ifaddrs design enforces this).  See the man page for getifaddrs.
        if let addr = ifaddr.ifa_dstaddr, 0 < addr.pointee.sa_len {
            return NetworkAddress(addr: addr)
        } else {
            // Workaround for getifaddrs bug whereby it never specifies broadcast addresses.  https://blog.wadetregaskis.com/getifaddrs-never-specifies-broadcast-addresses
            guard let addr = address?.IPv4Address,
                  let mask = netmask?.IPv4Address else { return nil }
            
            let broadcastAddr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                            sin_family: sa_family_t(AF_INET),
                                            sin_port: 0,
                                            sin_addr: in_addr(s_addr: addr | ~mask),
                                            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            
            return withUnsafePointer(to: broadcastAddr) {
                NetworkAddress(addr: UnsafeRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1))
            }
        }
    }
    
    /// The address of the other side of a point-to-point link.  Only applies to point-to-point links (as per ``pointToPoint``.
    public var destinationAddress: NetworkAddress? {
        guard flags.contains(.pointToPoint),
              let addr = ifaddr.ifa_dstaddr,
              0 < addr.pointee.sa_len else { // Sometimes getifaddrs returns ifa_dstaddr's that are invalid; sa_len & sa_family are zero.  e.g. for utunN interfaces.
            return nil
        }
        
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
        Flags(rawValue: ifaddr.ifa_flags)
    }
    
    /// Flags catagorising the behaviour, status, and configuration of the interface.
    ///
    /// These correspond to the `IFF_*` flags in `/usr/include/net/if.h`.  These are pretty uniform across all \*nix systems - you can find a lot of information online about what specifically each one means.  The meaning & purpose of many of them is esoteric and not of interest to most users - the most commonly noted ones are ``up`` (is the interface actually operating & connected to the network) and ``loopback`` (does the interface operate only on the current host, not actually out onto a shared network).
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
        public static let receivesAllMulticastPackets = Flags(rawValue: UInt32(IFF_MULTICAST))
        public static let transmissionInProgress = Flags(rawValue: UInt32(IFF_OACTIVE))
        public static let simplex = Flags(rawValue: UInt32(IFF_SIMPLEX))
        public static let link0 = Flags(rawValue: UInt32(IFF_LINK0))
        public static let link1 = Flags(rawValue: UInt32(IFF_LINK1))
        public static let link2 = Flags(rawValue: UInt32(IFF_LINK2))
        public static let usesAlternatePhysicalConnection = Flags(rawValue: UInt32(IFF_ALTPHYS))
        public static let supportsMulticast = Flags(rawValue: UInt32(IFF_MULTICAST))
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
    public var transmissionInProgress: Bool { flags.contains(.transmissionInProgress) }
    public var simplex: Bool { flags.contains(.simplex) }
    public var link0: Bool { flags.contains(.link0) }
    public var link1: Bool { flags.contains(.link1) }
    public var link2: Bool { flags.contains(.link2) }
    public var usesAlternatePhysicalConnection: Bool { flags.contains(.usesAlternatePhysicalConnection) }
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

            var result = [NetworkInterface]()
            
            guard let ifHead else {
                return result
            }
            
            let lifehook = Lifehook(ifHead)
            
            var ifNext: UnsafeMutablePointer<ifaddrs>? = ifHead
            
            while let ifCurrent = ifNext?.pointee {
                result.append(NetworkInterface(ifaddr: ifCurrent, lifehook: lifehook))
                ifNext = ifCurrent.ifa_next
            }
            
            return result
        }
    }
        
    public enum Errors: Error {
        /// The low-level OS-library function that retrieves all the information from the kernel, getifaddrs, failed with the given 'explanation' by way of an error number.  These error codes are defined in `/usr/include/sys/errno.h` (and exposed to Swift through the ``Darwin`` module), as e.g. ``Darwin/ENOMEM``.
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

/// A network address - e.g. 127.0.0.1 as an example IPv4 address, or 2601:647:4d01:93c4:813:a728:b5b3:1d32 as an example IPv6 address.
///
/// This structure is pretty lightweight - the address data is stored in an efficient binary form - and standalone (so you can keep copies of these addresses around as along as you like, without incurring any additional memory cost, unlike for ``NetworkInterface``).
public struct NetworkAddress {
    private let rawAddress: [UInt8]
    
    /// Initialises the address from the given `sockaddr` (meaning some logical, concrete subclass of the abstract base class`sockaddr`, such as `sockaddr_in` or `sockaddr_in6`).
    /// - Parameters:
    ///   - addr: The address in raw form.
    ///   - realSize: The _actual_ size (in bytes) of the `addr`, for cases where the inline size information (`sa_len`) is incorrect.
    ///
    ///     In principle this is never necessary, but in practice Apple's OS libraries have multiple bugs (in macOS 13.3.1 at least) where that inline size information is wrong.
    ///
    ///     Nonetheless, be very careful about overriding the inline size information via this parameter, as a `realSize` that is actually wrong can cause data corruption or crashes.  Unless you know very clearly otherwise, leave this parameter unspecified (or nil).
    init(addr: UnsafePointer<sockaddr>, realSize: Int? = nil) {
        let size = realSize ?? Int(addr.pointee.sa_len)
        
        rawAddress = .init(unsafeUninitializedCapacity: size) { buffer, initializedCount in
            initializedCount = addr.withMemoryRebound(to: UInt8.self, capacity: size) { transientAddr in
                buffer.initialize(fromContentsOf: UnsafeBufferPointer(start: transientAddr, count: size))
            }
        }
    }
    
    /// This is a redefinition of the constants defined in the OS's standard library headers (`AF_UNIX`, `AF_INET`, etc) and as exposed to Swift via the ``Darwin`` module.  They are redefined here because using the 'constants' directly from the Darwin module is annoying because they are (a) global, so no context-sensitive auto-completion possible and (b) not actualy defined as constants, so they can't be used in all contexts.
    ///
    /// Note that it's conceivable - but very unlikely - that there will be new address families added in future OS versions.  For this reason the ``unsupported`` case exists, representing a value returned by the underlying OS APIs that this Swift library doesn't know about.  If you ever encounter this please report it to the library authors at https://github.com/wadetregaskis/NetworkInterfaceInfo/issues.
    public enum AddressFamily: sa_family_t, CaseIterable {
        case unspecified = 0
        
        /// "Unix" or "local" addressing - this is for communication strictly between processes on the same host.  It is relatively secure and efficient.
        case unix = 1
        
        /// IPv4 addressing.
        case inet = 2
        
        case implink = 3
        case pup = 4
        case chaos = 5
        case ns = 6
        case iso = 7
        case ecma = 8
        case datakit = 9
        case ccitt = 10
        case sna = 11
        case decnet = 12
        case dli = 13
        case lat = 14
        case hylink = 15
        case appletalk = 16
        case route = 17
        case link = 18
        case xtp = 19
        case coip = 20
        case cnt = 21
        case rtip = 22
        case ipx = 23
        case sip = 24
        case pip = 25
        case ndrv = 27
        case isdn = 28
        case key = 29
        
        /// IPv6 addressing.
        case inet6 = 30
        
        case natm = 31
        case system = 32
        case netbios = 33
        case ppp = 34
        case hdrcmplt = 35
        case ieee802_11 = 37
        case utun = 38
        case vsock = 40
        
        case unsupported = 255
    }

    /// The 'family' of the address; what kind of network it applies to.
    ///
    /// The most common address families are ``AddressFamily/unix``, ``AddressFamily/inet``, and ``AddressFamily/inet6``.  There are convenience properties for those three common cases, ``isUnixLocal``, ``isIPv4``, and ``isIPv6`` respectively.
    public var family: AddressFamily {
        rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr.self) { sockaddrBuffer in
                AddressFamily(rawValue: sockaddrBuffer.baseAddress!.pointee.sa_family) ?? .unsupported
            }
        }
    }
    
    /// Indicates whether this address is a "Unix" or "local" address, meaning it is only usable for addressing & communication between processes on the same host.
    public var isUnixLocal: Bool {
        .unix == family
    }
    
    /// Indicates whether this address is an IPv4 address.
    public var isIPv4: Bool {
        .inet == family
    }
    
    /// Indicates whether this address is an IPv6 address.
    public var isIPv6: Bool {
        .inet6 == family
    }
    
    fileprivate var IPv4Address: in_addr_t? {
        guard isIPv4 else { return nil }
        
        return rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr_in.self) {
                $0.baseAddress!.pointer(to: \.sin_addr)!.pointee.s_addr
            }
        }
    }

    /// Only for initialising the special ``null``  constant.
    private init() {
        rawAddress = []
    }

    /// For internal use only.  A special 'null' placeholder for times where nullability is intrinsic but Optionals aren't permitted (e.g. dictionary keys, as in the change monitoring implementation).
    internal static let null = NetworkAddress()
}

extension NetworkAddress: Equatable, Hashable {}

extension NetworkAddress: CustomStringConvertible {
    private func ntop(family: sa_family_t, addr: UnsafeRawPointer, maximumSize: Int) -> String {
        return String(unsafeUninitializedCapacity: maximumSize) { buffer in
            var actualLength = -1
            
            buffer.withMemoryRebound(to: CChar.self) { buffer in
                if let cString = inet_ntop(Int32(family),
                                           addr,
                                           buffer.baseAddress,
                                           socklen_t(maximumSize)) {
                    actualLength = strnlen(cString, maximumSize)
                } else {
                    // TODO: throw exception?
                    actualLength = 0
                }
            }
            
            return actualLength
        }
    }
    
    /// Returns a human-readable (relatively speaking) form of the address.
    ///
    /// While this will always return a value that is technically correct, it doesn't return "pretty" addresses for all address families.  Only the most common (IPv4 & IPv6) get family-specific presentation - the rest are rendered simply as their family ID and a hexadecimal dump of the addressing information (which may include more than just the address itself, depending on how the OS represents those addresses at the lowest levels).
    public var description: String {
        rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr.self) { sockaddrBuffer in
                let ptr = sockaddrBuffer.baseAddress!
                
                guard let familyOffset = MemoryLayout<sockaddr>.offset(of: \.sa_family) else {
                    return "{sockaddr structure not known}"
                }
                
                guard rawAddress.count > familyOffset else {
                    return "{bogus}"
                }
                
                let family = ptr.pointee.sa_family
                
                switch family {
                case sa_family_t(AF_INET):
                    // As of macOS 13.3.1 (and presumably earlier) getifaddrs does some weird shit regarding sockaddr_in, truncating it to eight bytes for netmasks, sometimes.  https://blog.wadetregaskis.com/getifaddrs-returns-truncated-sockaddr_ins-for-af_inet-ifa_netmasks
                    //precondition(rawAddress.count >= MemoryLayout<sockaddr_in>.size)
                    
                    return rawBuffer.withMemoryRebound(to: sockaddr_in.self) { buffer in
                        return ntop(family: family,
                                    addr: buffer.baseAddress!.pointer(to: \.sin_addr)!,
                                    maximumSize: Int(INET_ADDRSTRLEN))
                    }
                case sa_family_t(AF_INET6):
                    precondition(rawAddress.count >= MemoryLayout<sockaddr_in6>.size)

                    return rawBuffer.withMemoryRebound(to: sockaddr_in6.self) { buffer in
                        return ntop(family: family,
                                    addr: buffer.baseAddress!.pointer(to: \.sin6_addr)!,
                                    maximumSize: Int(INET6_ADDRSTRLEN))
                    }
                case sa_family_t(AF_LINK):
                    precondition(rawAddress.count >= MemoryLayout<sockaddr_dl>.size)
                    
                    return rawBuffer.withMemoryRebound(to: sockaddr_dl.self) { buffer in
                        let addr = buffer.baseAddress!
                        let addressLength = Int(addr.pointee.sdl_alen)
                        let nameLength = Int(addr.pointee.sdl_nlen)
                        
                        guard 0 < addressLength else {
                            guard 0 < nameLength else {
                                return ""
                            }
                            
                            return addr.pointer(to: \.sdl_data)!.withMemoryRebound(to: UInt8.self, capacity: nameLength) {
                                let name = UnsafeBufferPointer(start: $0, count: nameLength)
                                
                                return (String(bytes: name, encoding: .utf8)
                                        ?? String(bytes: name, encoding: .ascii)
                                        ?? "{invalid}")
                            }
                        }
                        
                        return addr.pointer(to: \.sdl_data)!.withMemoryRebound(to: UInt8.self, capacity: nameLength + addressLength) {
                            let address = UnsafeBufferPointer(start: $0 + nameLength, count: addressLength)
                            
                            return Data(buffer: UnsafeBufferPointer(start: address.baseAddress,
                                                                    count: addressLength)).asHexString(uppercase: false, delimiterEvery: 1, delimiter: ":")
                        }
                    }
                default:
                    let dataForm = (2 <= rawBuffer.count
                                    ? Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress! + 2),
                                           count: rawBuffer.count - 2,
                                           deallocator: .none)
                                    : Data())
                    
                    return "{\(family): \(dataForm.asHexString(uppercase: false, delimiterEvery: 4))"
                }
            }
        }
    }
}

extension NetworkInterface.Flags: CaseIterable {
    public static var allCases: [Self] = [.up,
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
}

extension NetworkInterface.Flags: Hashable {}

extension NetworkInterface.Flags: CustomStringConvertible {
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
    
    public var description: String {
        let knownFlagBits = Self.allCases.filter { self.contains($0) }
        
        return (Set(knownFlagBits.map { Self.names[$0] ?? "Unknown" }).sorted()
                + self.subtracting(Self(knownFlagBits)).rawValue.bits.map { "0x" + String($0, radix: 16) })
                .joined(separator: ", ")
    }
}

extension NetworkAddress.AddressFamily: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unspecified:
            return "Unspecified"
        case .unix:
            return "Unix / Local"
        case .inet:
            return "IPv4"
        case .implink:
            return "IMP"
        case .pup:
            return "PUP"
        case .chaos:
            return "CHAOS"
        case .ns:
            return "Xerox NS"
        case .iso:
            return "ISO"
        case .ecma:
            return "ECMA"
        case .datakit:
            return "DataKit"
        case .ccitt:
            return "CCITT"
        case .sna:
            return "IBM SNA"
        case .decnet:
            return "DECnet"
        case .dli:
            return "DEC Direct Data Link"
        case .lat:
            return "LAT"
        case .hylink:
            return "NSC Hyperchannel"
        case .appletalk:
            return "AppleTalk"
        case .route:
            return "Internet Routing Protocol"
        case .link:
            return "Link layer"
        case .xtp:
            return "eXpress Transfer Protocol"
        case .coip:
            return "Connection-oriented IP / ST II"
        case .cnt:
            return "Computer Network Technology"
        case .rtip:
            return "RTIP"
        case .ipx:
            return "IPX"
        case .sip:
            return "SIP"
        case .pip:
            return "PIP"
        case .ndrv:
            return "NDRV"
        case .isdn:
            return "ISDN"
        case .key:
            return "Internet Key Management"
        case .inet6:
            return "IPv6"
        case .natm:
            return "Native ATM Access"
        case .system:
            return "System / Kernel Event Messaging"
        case .netbios:
            return "NetBIOS"
        case .ppp:
            return "PPP"
        case .hdrcmplt:
            return "HDRCMPLT"
        case .ieee802_11:
            return "IEEE 802.11"
        case .utun:
            return "UTUN"
        case .vsock:
            return "VM Sockets"
        case .unsupported:
            return "{Unsupported}"
        }
    }
}
