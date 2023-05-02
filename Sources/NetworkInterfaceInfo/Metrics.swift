#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Foundation

extension NetworkInterface {
    public struct Metrics {
        public enum InterfaceType: UInt8, CaseIterable {
            case other = 1
            case arpanetOldStyle = 2
            case arpanetHDH = 3
            case x25DDN = 4
            case x25 = 5
            case ethernet = 6
            case CMSA_CD = 7
            case tokenBus = 8
            case tokenRing = 9
            case MAN = 10
            case starlan = 11
            case proteon10Mb = 12
            case proteon80Mb = 13
            case hyperchannel = 14
            case FDDI = 15
            case LAPB = 16
            case SDLC = 17
            case T1 = 18
            case E1 = 19
            case ISDNBasic = 20
            case ISDNPrimary = 21
            case PTP = 22
            case PPP = 23
            case loopback = 24
            case EON = 25
            case experimentalEthernet = 26
            case NSIP = 27
            case SLIP = 28
            case ultra = 29
            case T3 = 30
            case SIP = 31
            case frameRelay = 32
            case RS232 = 33
            case parallelPort = 34
            case arcNet = 35
            case arcNetPlus = 36
            case ATM = 37
            case MIOX25 = 38
            case sonet = 39
            case x25PLE = 40
            case ISO_88022_LLC = 41
            case localtalk = 42
            case SMDSDXI = 43
            case frameRelayDCE = 44
            case v35 = 45
            case HSSI = 46
            case HIPPI = 47
            case modem = 48
            case AAL5 = 49
            case sonetPath = 50
            case sonetVT = 51
            case SMDSICIP = 52
            case proprietaryVirtual = 53
            case proprietaryMultiplexing = 54
            case GIF = 55
            case faith = 56
            case STF = 57
            case IETF_RFC_6282 = 64
            case layer2VLAN = 135
            case IEEE_802_3ad_linkAggregate = 136
            case firewire = 144
            case bridge = 209
            case encapsulation = 244
            case pfLogging = 245
            case pfsync = 246
            case CARP = 248
            case packetTap = 254
            case cellular = 255
        }

        public let interfaceType: InterfaceType

        public let frameTypeIDLength: UInt8

        //public let interfacePhysicalType: UInt8 // Seemingly always zero on macOS, and web search results suggest it's a never-implemented hangover from BSD.

        /// The size (in bytes) of the physical layer addresses (e.g. six for Ethernet, where MAC addresses are used).
        public let mediaAddressLength: UInt8

        /// The size (in bytes) of each transmission unit header (e.g. 14 for Ethernet, where a transmission unit is a packet).
        public let mediaHeaderLength: UInt8

        /// Maximum Transmission Unit.
        ///
        /// The maximum size of a single transmission (not counting link-layer overhead) via this interface (e.g. packet payload size, for packet-based interfaces).  Larger values nominally imply better efficiency and higher real-world throughput, but there are usually technical limits on how large this value can be (and there are potential downsides to large values in practice).
        ///
        /// e.g. on Ethernet 1,500 is a very common MTU, but sometimes it's smaller or much larger (e.g. 9,000 for "Jumbo" mode).
        public let MTU: UInt32

        public let routingMetric: UInt32

        /// Bits per second.
        ///
        /// Note that this is the theoretical or "fundamental" speed, not accounting for protocol & other overheads.  Actual speed as seen by end-applications will invariably be lower.
        public let lineSpeed: UInt64

        public let promiscuousListenerCount: UInt32
        public let currentSendQueueSize: UInt32
        public let maximumSendQueueSize: UInt32
        public let sendQueueDropCount: UInt32

        public struct Counters {
            public let bytes: UInt64
            public let packets: UInt64
            public let packetsViaMulticast: UInt64
            public let errors: UInt64 /// Unit is packets.
            public let queueDrops: UInt64 /// Only applies to input; always 0 for output.  Unit is packets.
            public let timing: UInt32
            public let quota: UInt8
        }

        public let input: Counters
        public let output: Counters

        public let collisions: UInt64
        public let packetsWithMissingOrUnsupportedProtocol: UInt64

        public let timeOfLastAdministrativeChange: Date

        /// Initialises with data for the given named interface.
        public init(interface: String) throws {
            var index: UInt32 = 0

            interface.utf8CString.withUnsafeBytes {
                index = if_nametoindex($0.baseAddress)
            }

            guard 0 < index else {
                throw Errors.invalidInterfaceName(interface)
            }

            try self.init(interfaceIndex: index)
        }

        /// Initialises with data for the given interface by index.
        ///
        /// Interfaces are given arbitrary indexes by the OS kernel.  Generally it's preferable to refer to them via their name (e.g. "en0") and thus use the ``init(interface:)`` initialiser instead, but this variant initialiser is provided in case you're provided only the interface index by some other API.
        public init(interfaceIndex: UInt32) throws {
            // Thanks to Milen Dzhumerov for his post "macOS Network Metrics Using sysctl()" (https://milen.me/writings/macos-network-metrics-sysctl-net-rt-iflist2) plus example C code (https://github.com/milend/macos-network-metrics/blob/main/main.c) which were used a references for implementing this.

            var MIB: [Int32] = [CTL_NET,
                                PF_LINK,
                                NETLINK_GENERIC,
                                IFMIB_IFDATA,
                                Int32(interfaceIndex),
                                IFDATA_GENERAL]
            let MIBSize = UInt32(MIB.count) // Sigh… Swift won't allow direct access to MIB from inside the closure below.

            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size

            try MIB.withUnsafeMutableBufferPointer {
                guard 0 == sysctl($0.baseAddress, MIBSize, &data, &size, nil, 0) else {
                    throw Errors.sysctlFailed(errno: errno)
                }
            }

            promiscuousListenerCount = data.ifmd_pcount
            currentSendQueueSize = data.ifmd_snd_len
            maximumSendQueueSize = data.ifmd_snd_maxlen
            sendQueueDropCount = data.ifmd_snd_drops

            interfaceType = InterfaceType(rawValue: data.ifmd_data.ifi_type) ?? .other
            frameTypeIDLength = data.ifmd_data.ifi_typelen
            //interfacePhysicalType = data.ifmd_data.ifi_physical
            mediaAddressLength = data.ifmd_data.ifi_addrlen
            mediaHeaderLength = data.ifmd_data.ifi_hdrlen
            MTU = data.ifmd_data.ifi_mtu
            routingMetric = data.ifmd_data.ifi_metric
            lineSpeed = data.ifmd_data.ifi_baudrate

            input = Counters(bytes: data.ifmd_data.ifi_ibytes,
                             packets: data.ifmd_data.ifi_ipackets,
                             packetsViaMulticast: data.ifmd_data.ifi_imcasts,
                             errors: data.ifmd_data.ifi_ierrors,
                             queueDrops: data.ifmd_data.ifi_iqdrops,
                             timing: data.ifmd_data.ifi_recvtiming,
                             quota: data.ifmd_data.ifi_recvquota)

            output = Counters(bytes: data.ifmd_data.ifi_obytes,
                              packets: data.ifmd_data.ifi_opackets,
                              packetsViaMulticast: data.ifmd_data.ifi_omcasts,
                              errors: data.ifmd_data.ifi_oerrors,
                              queueDrops: 0,
                              timing: data.ifmd_data.ifi_xmittiming,
                              quota: data.ifmd_data.ifi_xmitquota)

            collisions = data.ifmd_data.ifi_collisions
            packetsWithMissingOrUnsupportedProtocol = data.ifmd_data.ifi_noproto

            timeOfLastAdministrativeChange = Date(timeIntervalSince1970: Double(data.ifmd_data.ifi_lastchange.tv_sec) + (Double(data.ifmd_data.ifi_lastchange.tv_usec) / 1_000_000))
        }
    }

    /// Metrics about the interface, including key numbers like packet & byte counts.
    ///
    /// The contents are fetched anew every time this property is accessed.  For efficiency and to get self-consistent numbers you should save the value into a local constant each time you use it (if you're using more than one field from within it).
    ///
    /// Note that this is tied to the underlying hardware interface, so you will get identical values (notwithstanding the effects of different access timing) across all ``NetworkInterface`` instances that involve the same hardware interface.
    public var metrics: Metrics {
        get throws {
            try Metrics(interface: name)
        }
    }
}

extension NetworkInterface.Metrics.Counters: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Counters(bytes: \(bytes), packets: \(packets), packetsViaMulticast: \(packetsViaMulticast), errors: \(errors), queueDrops: \(queueDrops), timing: \(timing), quota: \(quota))"
    }
}
