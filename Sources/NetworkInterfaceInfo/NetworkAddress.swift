#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Foundation

/// A network address - e.g. 127.0.0.1 as an example IPv4 address, or 2601:647:4d01:93c4:813:a728:b5b3:1d32 as an example IPv6 address.
///
/// This structure is pretty lightweight - the address data is stored in an efficient binary form - and standalone (so you can keep copies of these addresses around as along as you like, without incurring any additional memory cost, unlike for ``NetworkInterface``).
public struct NetworkAddress: Sendable {
    @usableFromInline
    internal let rawAddress: [UInt8]

#if canImport(Darwin)
    /// Initialises the address from the given `sockaddr` (meaning some logical, concrete subclass of the abstract base class`sockaddr`, such as `sockaddr_in` or `sockaddr_in6`).
    /// - Parameters:
    ///   - addr: The address in raw form.
    ///   - realSize: The _actual_ size (in bytes) of the `addr`, for cases where the inline size information (`sa_len`) is incorrect.
    ///
    ///     In principle this is never necessary, but in practice Apple's OS libraries have multiple bugs (in macOS 13.3.1 at least) where that inline size information is wrong.
    ///
    ///     Nonetheless, be very careful about overriding the inline size information via this parameter, as a `realSize` that is actually wrong can cause data corruption or crashes.  Unless you know very clearly otherwise, leave this parameter unspecified (or nil).
    @usableFromInline
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
    @usableFromInline
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
    public enum AddressFamily: sa_family_t, CaseIterable, Sendable {
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
    @inlinable
    public var family: AddressFamily {
        rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr.self) { sockaddrBuffer in
                AddressFamily(rawValue: sockaddrBuffer.baseAddress!.pointee.sa_family) ?? .unsupported
            }
        }
    }

    /// Indicates whether this address is a "Unix" or "local" address, meaning it is only usable for addressing & communication between processes on the same host.
    @inlinable
    @inline(__always)
    public var isUnixLocal: Bool {
        .unix == family
    }

    /// Indicates whether this address is an IPv4 address.
    @inlinable
    @inline(__always)
    public var isIPv4: Bool {
        .inet == family
    }

    /// Indicates whether this address is an IPv6 address.
    @inlinable
    @inline(__always)
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
    @usableFromInline
    internal static func ntop(family: sa_family_t, addr: UnsafeRawPointer, maximumSize: Int) -> String {
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
