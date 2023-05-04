#if canImport(Darwin)
import Darwin
#else
import Glibc

// Annoyingly, /usr/include/netinet/in.h on Linux* is missing some constants.  [* = It's assumed here that if Darwin isn't available we're running on Linux, where Glibc is]
let IN_CLASSD_NET = UInt32(0xf0000000)
let INADDR_CARP_GROUP = UInt32(0xe0000012)
let IN_LINKLOCALNETNUM = UInt32(0xa9fe0000) // This one at least makes sense - it _is_ an Apple-specific one.
let INADDR_ALLRPTS_GROUP = UInt32(0xe0000016)
let INADDR_PFSYNC_GROUP = UInt32(0xe00000f0)
let INADDR_ALLMDNS_GROUP = UInt32(0xe00000fb)
#endif

import Foundation

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
    public var IPv4: IPv4Address? {
        guard isIPv4 else {
            return nil
        }

        // This precondition should in principle apply universally, but on Apple platforms (e.g. macOS 13.3.1) getifaddrs does some weird shit regarding sockaddr_in, truncating it to eight bytes for netmasks, sometimes.  https://blog.wadetregaskis.com/getifaddrs-returns-truncated-sockaddr_ins-for-af_inet-ifa_netmasks
#if !canImport(Darwin)
        precondition(rawAddress.count >= MemoryLayout<sockaddr_in>.size)
#endif

        return IPv4Address(addressInNetworkOrder: rawAddress.withUnsafeBufferPointer { rawBuffer in
            rawBuffer.withMemoryRebound(to: sockaddr_in.self) {
                $0.baseAddress!.pointer(to: \.sin_addr)!.pointee.s_addr
            }
        })
    }

    /// A view over an IPv4 address, for examing IPv4-specific attributes.
    ///
    /// This is typically obtained using the ``NetworkAddress/IPv4`` property on ``NetworkAddress``, but it has publicly-accessible initialisers in case you want to use it for addresses you obtain elsewhere (e.g. from a different networking package or API).
    public struct IPv4Address: Sendable {
        /// The address (in host byte order).
        public let address: UInt32

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

        /// Indicates whether this address is the [DVMRP](https://en.wikipedia.org/wiki/Distance_Vector_Multicast_Routing_Protocol) multicast group (224.0.0.4).
        public var isDVMRPMulticastGroup: Bool {
            address == 0xe000_0004
        }

        /// Indicates whether this address is the [OSPF](https://en.wikipedia.org/wiki/Open_Shortest_Path_First) multicast group (224.0.0.5).
        public var isOSPFMulticastGroup: Bool {
            address == 0xe000_0005
        }

        /// Indicates whether this address is the [OSPF](https://en.wikipedia.org/wiki/Open_Shortest_Path_First) DR multicast group (224.0.0.5).
        public var isOSPFDRMulticastGroup: Bool {
            address == 0xe000_0006
        }

        /// Indicates whether this address is the [RIPv2](https://en.wikipedia.org/wiki/Routing_Information_Protocol) multicast group (224.0.0.9).
        public var isRIPv2MulticastGroup: Bool {
            address == 0xe000_0009
        }

        /// Indicates whether this address is the [EIGRP](https://en.wikipedia.org/wiki/Enhanced_Interior_Gateway_Routing_Protocol) multicast group (224.0.0.10).
        public var isEIGRPMulticastGroup: Bool {
            address == 0xe000_000a
        }

        /// Indicates whether this address is the [PIMv2](https://en.wikipedia.org/wiki/Protocol_Independent_Multicast) multicast group (224.0.0.13).
        public var isPIMv2MulticastGroup: Bool {
            address == 0xe000_000d
        }

        /// Indicates whether this address is the [VRRP](https://en.wikipedia.org/wiki/Virtual_Router_Redundancy_Protocol) multicast group (224.0.0.18).
        public var isVRRPMulticastGroup: Bool {
            address == 0xe000_0012
        }

        /// Indicates whether this address is the [CARP](https://en.wikipedia.org/wiki/Common_Address_Redundancy_Protocol) (Common Address Redundancy Protocol) multicast group (224.0.0.18).
        public var isCARPMulticastGroup: Bool {
            address == INADDR_CARP_GROUP
        }

        /// Indicates whether this address is the [IGMPv3](https://en.wikipedia.org/wiki/Internet_Group_Management_Protocol) multicast group (224.0.0.22).
        public var isIGMPv3MulticastGroup: Bool {
            address == INADDR_ALLRPTS_GROUP
        }

        /// Indicates whether this address is the [PTPv2](https://en.wikipedia.org/wiki/Precision_Time_Protocol) delay measurement multicast group (224.0.0.107).
        public var isPTPv2DelayMeasurementMulticastGroup: Bool {
            address == 0xe000_006b
        }

        /// Indicates whether this address is the [PTPv2](https://en.wikipedia.org/wiki/Precision_Time_Protocol) general messages multicast group (224.0.1.129).
        public var isPTPv2GeneralMessagesMulticastGroup: Bool {
            address == 0xe000_0181
        }

        /// Indicates whether this address is the [PfSync](https://en.wikipedia.org/wiki/Pfsync) multicast group (224.0.0.240).
        public var isPfsyncMulticastGroup: Bool {
            address == INADDR_PFSYNC_GROUP
        }

        /// Indicates whether this address is the multicast DNS ([mDNS](https://en.wikipedia.org/wiki/Multicast_DNS)) multicast group (224.0.0.251).
        public var ismDNSMulticastGroup: Bool {
            address == INADDR_ALLMDNS_GROUP
        }

        /// Indicates whether this address is the [LLMNR](https://en.wikipedia.org/wiki/Link-local_Multicast_Name_Resolution) multicast group (224.0.0.252).
        public var isLLMNRMulticastGroup: Bool {
            address == 0xe000_00fc
        }

        /// Indicates whether this address is the [Teredo](https://en.wikipedia.org/wiki/Teredo_tunneling) client discovery multicast group (224.0.0.253).
        public var isTeredoMulticastGroup: Bool {
            address == 0xe000_00fd
        }

        /// Indicates whether this address is the [NTP](https://en.wikipedia.org/wiki/Network_Time_Protocol) multicast group (224.0.1.1).
        public var isNTPMulticastGroup: Bool {
            address == 0xe000_0101
        }

        /// Indicates whether this address is the [SLPv1](https://en.wikipedia.org/wiki/Service_Location_Protocol) general multicast group (224.0.1.22).
        public var isSLPv1GeneralMulticastGroup: Bool {
            address == 0xe000_0116
        }

        /// Indicates whether this address is the [SLPv1](https://en.wikipedia.org/wiki/Service_Location_Protocol) directory agent multicast group (224.0.1.35).
        public var isSLPv1DirectoryAgentMulticastGroup: Bool {
            address == 0xe000_0123
        }

        /// Indicates whether this address is the [SLPv2](https://en.wikipedia.org/wiki/Service_Location_Protocol) multicast group (239.255.255.253).
        public var isSLPv2MulticastGroup: Bool {
            address == 0xefff_fffd // Someone had a sense of humour, and/or didn't believe in their protocol.
        }

        /// Indicates whether this address is the [SSDP](https://en.wikipedia.org/wiki/Simple_Service_Discovery_Protocol) multicast group (239.255.255.250).
        public var isSSDPMulticastGroup: Bool {
            address == 0xefff_fffa
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

extension NetworkAddress.IPv4Address: CustomStringConvertible {
    public var description: String {
        var networkOrderedAddress = in_addr(s_addr: address.bigEndian)

        return NetworkAddress.ntop(family: sa_family_t(AF_INET),
                                   addr: &networkOrderedAddress,
                                   maximumSize: Int(INET_ADDRSTRLEN))
    }
}

extension NetworkAddress.IPv4Address: Equatable, Hashable {}
