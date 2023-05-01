#if canImport(Darwin)
import Darwin
#else
import Glibc

public typealias errno_t = Int32

// Annoyingly, /usr/include/netinet/in.h on Linux* is missing some constants.  [* = It's assumed here that if Darwin isn't available we're running on Linux, where Glibc is]
let IN_CLASSD_NET = UInt32(0xf0000000)
let INADDR_CARP_GROUP = UInt32(0xe0000012)
let IN_LINKLOCALNETNUM = UInt32(0xa9fe0000) // This one at least makes sense - it _is_ an Apple-specific one.
let INADDR_ALLRPTS_GROUP = UInt32(0xe0000016)
let INADDR_PFSYNC_GROUP = UInt32(0xe00000f0)
let INADDR_ALLMDNS_GROUP = UInt32(0xe00000fb)
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

/// A network address - e.g. 127.0.0.1 as an example IPv4 address, or 2601:647:4d01:93c4:813:a728:b5b3:1d32 as an example IPv6 address.
///
/// This structure is pretty lightweight - the address data is stored in an efficient binary form - and standalone (so you can keep copies of these addresses around as along as you like, without incurring any additional memory cost, unlike for ``NetworkInterface``).
public struct NetworkAddress {
    private let rawAddress: [UInt8]

#if canImport(Darwin)
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
#else
    private static func deduceSize(_ addr: UnsafePointer<sockaddr>) -> Int? {
        switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                return MemoryLayout<sockaddr_in>.size
            case AF_UNIX:
                return MemoryLayout<sockaddr_un>.size
            case AF_INET6:
                return MemoryLayout<sockaddr_in6>.size
            default: // At time of writing only the above three sockaddr_foo 'subclasses' exist in Glibc (as of Swift 5.8 on whatever distro GitHub's Codespaces use).  Surely more are actually defined in the system headers - presumably this indicates an incomplete implementation of Glibc (the Swift wrapper library).
                return nil
        }
    }

    /// Initialises the address from the given `sockaddr` (meaning some logical, concrete subclass of the abstract base class`sockaddr`, such as `sockaddr_in` or `sockaddr_in6`), if possible.
    /// - Parameters:
    ///   - addr: The address in raw form.
    ///   - realSize: The _actual_ size (in bytes) of the `addr`.
    ///
    ///     If this is not supplied it will be deduced - iff possible - from the address family specified in `addr`.  Note that this deduction might fail to produce an answer, which is why this initialiser can fail and return nil instead.  Currently only AF_UNIX, AF_INET, and AF_INET6 address families are supported in this manner.
    ///
    ///     Be very careful about overriding the inline size information via this parameter, as a `realSize` that is actually wrong can cause data corruption or crashes.  Unless you know very clearly otherwise, leave this parameter unspecified (or nil).
    init?(addr: UnsafePointer<sockaddr>, realSize: Int? = nil) {
        guard let size = realSize ?? NetworkAddress.deduceSize(addr) else {
            return nil
        }

        rawAddress = .init(unsafeUninitializedCapacity: size) { buffer, initializedCount in
            initializedCount = addr.withMemoryRebound(to: UInt8.self, capacity: size) { transientAddr in
                buffer.initialize(fromContentsOf: UnsafeBufferPointer(start: transientAddr, count: size))
            }
        }
    }
#endif
    
    /// This is a redefinition of the constants defined in the OS's standard library headers (`AF_UNIX`, `AF_INET`, etc) and as exposed to Swift via the ``Darwin`` or ``Glibc`` module.  They are redefined here because using the 'constants' directly from that module is annoying because they are (a) global, so no context-sensitive auto-completion possible and (b) not actualy defined as constants, so they can't be used in all contexts.
    ///
    /// Note that it's conceivable - but very unlikely - that there will be new address families added in future OS versions.  For this reason the ``unsupported`` case exists, representing a value returned by the underlying OS APIs that this Swift library doesn't know about.  If you ever encounter this please report it to the library authors at https://github.com/wadetregaskis/NetworkInterfaceInfo/issues.
    public enum AddressFamily: sa_family_t, CaseIterable {
        case unspecified = 0
        
        /// "Unix" or "local" addressing - this is for communication strictly between processes on the same host.  It is relatively secure and efficient.
        case unix = 1
        
        /// IPv4 addressing.
        case inet = 2
        
#if canImport(Darwin)
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
#else
        case ax25 = 3
        case ipx = 4
        case appletalk = 5
        case netrom = 6
        case bridge = 7
        case atmpvc = 8
        case x25 = 9

        /// IPv6 addressing.
        case inet6 = 10

        case x25_plp = 11
        case decnet = 12
        case netbeui = 13
        case security = 14
        case key = 15
        case route = 16
        case packet = 17
        case ash = 18
        case econet = 19
        case atmsvc = 20
        case rds = 21
        case sna = 22
        case irda = 23
        case pppox = 24
        case wanpipe = 25
        case llc = 26
        case infiniband = 27
        case mpls = 28
        case can = 29
        case tipc = 30
        case bluetooth = 31
        case iucv = 32
        case rxrpc = 33
        case isdn = 34
        case phonet = 35
        case ieee802_15_4 = 36
        case caif = 37
        case algorithm = 38
        case nfc = 39
        case vsocket = 40
        case kcm = 41
        case qipcrtr = 42
        case smc = 43
        case xdp = 44
        case mctp = 45
#endif
        
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

    /// Only for initialising the special ``null``  constant.
    private init() {
        rawAddress = []
    }

    /// For internal use only.  A special 'null' placeholder for times where nullability is intrinsic but Optionals aren't permitted (e.g. dictionary keys, as in the change monitoring implementation).
    internal static let null = NetworkAddress()
}

extension NetworkAddress: Equatable, Hashable {}

extension NetworkAddress: CustomStringConvertible {
    fileprivate static func ntop(family: sa_family_t, addr: UnsafeRawPointer, maximumSize: Int) -> String {
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
    /// While this will always return a value that is technically correct, it doesn't return "pretty" addresses for all address families.  Only the most common (e.g. IPv4 & IPv6) get family-specific presentation - the rest are rendered simply as their family ID and a hexadecimal dump of the addressing information (which may include more than just the address itself, depending on how the OS represents those addresses at the lowest levels).
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
                    return IPv4!.description
                case sa_family_t(AF_INET6):
                    precondition(rawAddress.count >= MemoryLayout<sockaddr_in6>.size)

                    return rawBuffer.withMemoryRebound(to: sockaddr_in6.self) { buffer in
                        return NetworkAddress.ntop(family: family,
                                                   addr: buffer.baseAddress!.pointer(to: \.sin6_addr)!,
                                                   maximumSize: Int(INET6_ADDRSTRLEN))
                    }
#if canImport(Darwin) // Glibc is missing sockaddr_dl, at least at time of writing using Swift 5.8 on whatever distro GitHub's Codespaces uses.
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
#endif
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

extension NetworkAddress {
    /// A view which provides IPv4-specific properties.
    ///
    /// This is nil for NetworkAddresses that do not contain IPv4 addresses.
    ///
    /// Note that while you can use ``isIPv4`` first to determine if this property should be non-nil or not, it is simpler and safer to use `if let` or `guard let`, e.g.:
    ///
    ///     guard let IPv4 = address.IPv4 else {
    ///         return
    ///     }
    ///
    ///     // Now you can use `IPv4`.
    public var IPv4: IPv4View? {
        guard isIPv4 else {
            return nil
        }

        // This precondition should in principle apply universally, but on Apple platforms (e.g. macOS 13.3.1) getifaddrs does some weird shit regarding sockaddr_in, truncating it to eight bytes for netmasks, sometimes.  https://blog.wadetregaskis.com/getifaddrs-returns-truncated-sockaddr_ins-for-af_inet-ifa_netmasks
#if !canImport(Darwin)
        precondition(rawAddress.count >= MemoryLayout<sockaddr_in>.size)
#endif

        return IPv4View(addressInNetworkOrder: rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr_in.self) {
                $0.baseAddress!.pointer(to: \.sin_addr)!.pointee.s_addr
            }
        })
    }

    /// A view over an IPv4 address, for examing IPv4-specific attributes.
    ///
    /// This is typically obtained using the ``NetworkAddress/IPv4`` property on ``NetworkAddress``, but it has publicly-accessible initialisers in case you want to use it for addresses you obtain elsewhere (e.g. from a different networking package or API).
    public struct IPv4View {
        /// The address (in host byte order).
        fileprivate let address: UInt32

        /// - Parameter address: The address (in host byte order).
        public init(addressInHostOrder: UInt32) {
            self.address = addressInHostOrder
        }

        /// - Parameter address: The address (in network byte order).
        public init(addressInNetworkOrder: UInt32) {
            self.address = UInt32(bigEndian: addressInNetworkOrder)
        }

        /// Indicates whether this (IPv4) address is the loopback address (127.0.0.1).
        public var isLoopback: Bool {
            address == INADDR_LOOPBACK
        }

        /// Indicates whether this netmask is a class A network (255.0.0.0).
        public var isClassANetwork: Bool {
            address == IN_CLASSA_NET
        }

        /// Indicates whether this address is in a class A network.
        public var inClassANetwork: Bool {
            (address & 0x8000_0000) == 0
        }

        /// Indicates whether this netmask is a class B network (255.255.0.0)
        public var isClassBNetwork: Bool {
            address == IN_CLASSB_NET
        }

        /// Indicates whether this address is in a class B network.
        public var inClassBNetwork: Bool {
            (address & 0xC000_0000) == 0x8000_0000
        }

        /// Indicates whether this netmask is a class C network (255.255.255.0).
        public var isClassCNetwork: Bool {
            address == IN_CLASSC_NET
        }

        /// Indicates whether this address is in a class C network.
        public var inClassCNetwork: Bool {
            (address & 0xE000_0000) == 0xC000_0000
        }

        /// Indicates whether this netmask is a class D network (multicast).
        public var isClassDNetwork: Bool {
            address == IN_CLASSD_NET
        }

        /// Indicates whether this address is in a class D network (multicast).
        public var inClassDNetwork: Bool {
            (address & 0xF000_0000) == 0xE000_0000
        }

        /// Indicates whether this address is in a link local network (169.254.x.x).
        public var inLinkLocalNetwork: Bool {
            (address & IN_CLASSB_NET) == IN_LINKLOCALNETNUM
        }

        /// Indicates whether this address is in a loopback network (127.x.x.x).
        public var inLoopbackNetwork: Bool {
            (address & IN_CLASSA_NET) == 0x7f00_0000
        }

        /// Indicates whether this address is in a private network (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16).
        public var inPrivateNetwork: Bool {
            return (address & IN_CLASSA_NET) == 0x0a00_0000 // 10.0.0.0/8
                || (address & 0xfff0_0000)  ==  0xac10_0000 // 172.16.0.0/12
                || (address & IN_CLASSB_NET) == 0xac10_0000 // 192.168.0.0/16
        }

        /// Indicates whether this address is the unspecified broadcast group (224.0.0.0)
        public var isUnspecifiedMulticastGroup: Bool {
            address == INADDR_UNSPEC_GROUP
        }

        /// Indicates whether this address is the all hosts multicast group address (224.0.0.1).
        public var isAllHostsMulticastGroup: Bool {
            address == INADDR_ALLHOSTS_GROUP
        }

        /// Indicates whether this address is the all routers multicast group (224.0.0.2).
        public var isAllRoutersMulticastGroup: Bool {
            address == INADDR_ALLRTRS_GROUP
        }

        /// Indicates whether this address is the [CARP](https://en.wikipedia.org/wiki/Common_Address_Redundancy_Protocol) (Common Address Redundancy Protocol) multicast group (224.0.0.18).
        public var isCARPMulticastGroup: Bool {
            address == INADDR_CARP_GROUP
        }

        /// Indicates whether this address is the [IGMPv3](https://en.wikipedia.org/wiki/Internet_Group_Management_Protocol) multicast group (224.0.0.22).
        public var isIGMPv3MulticastGroup: Bool {
            address == INADDR_ALLRPTS_GROUP
        }

        /// Indicates whether this address is the [PfSync](https://en.wikipedia.org/wiki/Pfsync) multicast group (224.0.0.240).
        public var isPfsyncMulticastGroup: Bool {
            address == INADDR_PFSYNC_GROUP
        }

        /// Indicates whether this address is the multicast DNS ([mDNS](https://en.wikipedia.org/wiki/Multicast_DNS)) multicast group (224.0.0.251).
        public var ismDNSMulticastGroup: Bool {
            address == INADDR_ALLMDNS_GROUP
        }

        /// Indicates whether this address is in a multicast network (224.x.x.x).
        public var inMulticastGroup: Bool {
            (address & IN_CLASSD_NET) == INADDR_UNSPEC_GROUP
        }

        /// Indicates whether this address is in a local multicast group (224.0.0.x).
        public var inLocalMulticastGroup: Bool {
           (address & IN_CLASSC_NET) == INADDR_UNSPEC_GROUP
        }
    }
}

extension NetworkAddress.IPv4View: CustomStringConvertible {
    public var description: String {
        var networkOrderedAddress = in_addr(s_addr: address.bigEndian)

        return NetworkAddress.ntop(family: sa_family_t(AF_INET),
                                   addr: &networkOrderedAddress,
                                   maximumSize: Int(INET_ADDRSTRLEN))
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

extension NetworkAddress.AddressFamily: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unspecified:
            return "Unspecified"
        case .unix:
            return "Unix / Local"
        case .inet:
            return "IPv4"
#if canImport(Darwin)
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
        case .dli:
            return "DEC Direct Data Link"
        case .lat:
            return "LAT"
        case .hylink:
            return "NSC Hyperchannel"
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
        case .sip:
            return "SIP"
        case .pip:
            return "PIP"
        case .ndrv:
            return "NDRV"
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
#else
        case .ax25:
            return "AX.25"
        case .netrom:
            return "NET/ROM"
        case .bridge:
            return "Multiprotocol bridge"
        case .atmpvc:
            return "ATM PVC"
        case .x25:
            return "X.25"
        case .x25_plp:
            return "X.25 PLP"
        case .netbeui:
            return "NetBEUI"
        case .security:
            return "Security"
        case .packet:
            return "Packet"
        case .ash:
            return "Ash"
        case .econet:
            return "Econet"
        case .atmsvc:
            return "ATM SVC"
        case .rds:
            return "RDS"
        case .irda:
            return "IRDA"
        case .pppox:
            return "PPPoX"
        case .wanpipe:
            return "Wanpipe"
        case .llc:
            return "LLC"
        case .infiniband:
            return "Infiniband"
        case .mpls:
            return "MPLS"
        case .can:
            return "CAN"
        case .tipc:
            return "TIPC"
        case .bluetooth:
            return "Bluetooth"
        case .iucv:
            return "IUCV"
        case .rxrpc:
            return "RxRPC"
        case .phonet:
            return "Phonet"
        case .ieee802_15_4:
            return "IEEE 802.15.4"
        case .caif:
            return "CAIF"
        case .algorithm:
            return "Algorithm"
        case .nfc:
            return "NFC"
        case .vsocket:
            return "vSocket"
        case .kcm:
            return "KCM"
        case .qipcrtr:
            return "Qualcomm IPC Router"
        case .smc:
            return "SMC"
        case .xdp:
            return "XDP"
        case .mctp:
            return "MCTP"
#endif
        case .sna:
            return "IBM SNA"
        case .decnet:
            return "DECnet"
        case .appletalk:
            return "AppleTalk"
        case .route:
            return "Internet Routing Protocol"
        case .ipx:
            return "IPX"
        case .isdn:
            return "ISDN"
        case .key:
            return "Internet Key Management"
        case .inet6:
            return "IPv6"
        case .unsupported:
            return "{Unsupported}"
        }
    }
}
