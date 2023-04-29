import Dispatch
@preconcurrency import Network
import NetworkInterfaceInfo

public extension NetworkInterface {
    /// Encapsulates a change to a ``NetworkInterfaceInfo/NetworkInterface/all``.
    struct Change {
        /// The nature of an interface change - i.e. whether it is new (``added``), ``modified``, or has disappeared (``removed``).
        public enum Nature {
            /// The interface appears to be new (no similar interfaces previously existed, based on address family, address, netmask, etc).
            case added

            /// The interface has been modified.  The associated value provides an indication of what specific aspects of the interface have changed.
            case modified(ModificationNature)

            /// The interface appears to have been removed (no similar interfaces now exist, based on address family, address, netmask, etc).
            case removed
        }

        /// Indicates which parts of a ``NetworkInterfaceInfo/NetworkInterface`` have changed.
        public struct ModificationNature: OptionSet {
            public let rawValue: Int8

            public static let address            = ModificationNature(rawValue: 1 << 0)
            public static let netmask            = ModificationNature(rawValue: 1 << 1)
            public static let broadcastAddress   = ModificationNature(rawValue: 1 << 2)
            public static let destinationAddress = ModificationNature(rawValue: 1 << 3)
            public static let flags              = ModificationNature(rawValue: 1 << 4)

            public init(rawValue: Int8) {
                self.rawValue = rawValue
            }
        }

        /// The nature of the change - whether it represents a new interface, and interface that's just disappeared, or one that has been modified in some manner.  In the latter case an indication of what changed is provided via
        public let nature: Nature
        public let interface: NetworkInterface

        fileprivate init(nature: Nature, interface: NetworkInterface) {
            self.nature = nature
            self.interface = interface
        }
    }

    /// Reports changes to ``NetworkInterfaceInfo/NetworkInterface/all``.
    ///
    /// The returned stream is endless - awaiting its next value will block (as needed) until the next change occurs.
    ///
    /// Changes are reported as a simple structure - ``Change`` - that provides an indication not only of what ``NetworkInterface`` changed by in what manner; whether it is newly added, just removed, or modified (with indications of which fields were modified).
    ///
    /// Note that some modifications may be reported as first a removal and then an addition.  This reflects how the underlying system actually manages these interfaces, sometimes, even for seemingly trivial modifications like changing the IP address on an interface.
    ///
    /// Note that there is no upper bound on when changes are reported via this stream.  It relies on the ``Network//NWPathMonitor`` functionality from Apple, and while sometimes Apple's library provides notification of changes virtually immediately, at other times it can take minute(s).
    static var changes: AsyncThrowingStream<Change, Error> {
        AsyncThrowingStream { continuation -> Void in
            var lastInterfaces: Set<NetworkInterface>

            do {
                lastInterfaces = Set(try NetworkInterface.all)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            for interface in lastInterfaces {
                continuation.yield(Change(nature: .added, interface: interface))
            }

            let monitor = NWPathMonitor()

            monitor.pathUpdateHandler = { _ in
                do {
                    let currentInterfaces = Set(try NetworkInterface.all)
                    let newOrChangedInterfaces = currentInterfaces.subtracting(lastInterfaces)
                    var goneOrChangedInterfaces = lastInterfaces.subtracting(currentInterfaces)

                    for interface in newOrChangedInterfaces {
                        let potentials = goneOrChangedInterfaces.compactMap { other -> (Int, NetworkInterface)? in
                            guard let score = interface.similarityScore(versus: other) else {
                                return nil
                            }

                            return (score, other)
                        }

//                        print("Candidate origins of \(interface):")
//                        dump(potentials)

                        if let bestMatch = potentials.reduce(nil, { candidate, other -> (Int, NetworkInterface)? in
                            guard let candidate else {
                                return other
                            }

                            if candidate.0 > other.0 {
                                return candidate
                            } else {
                                return other
                            }
                        })?.1 {
                            continuation.yield(Change(nature: .modified(interface.changes(versus: bestMatch)),
                                                      interface: interface))

                            goneOrChangedInterfaces.remove(bestMatch)
                        } else {
                            continuation.yield(Change(nature: .added, interface: interface))
                        }
                    }

                    for interface in goneOrChangedInterfaces {
                        continuation.yield(Change(nature: .removed, interface: interface))
                    }

                    lastInterfaces = currentInterfaces
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                monitor.cancel()
            }

            monitor.start(queue: DispatchQueue(label: "NetworkInterface.changes"))
        }
    }
}

fileprivate extension NetworkInterface {
    func changes(versus other: NetworkInterface) -> Change.ModificationNature {
        var nature = Change.ModificationNature()

        if other.address != address {
            nature.insert(.address)
        }

        if other.netmask != netmask {
            nature.insert(.netmask)
        }

        if other.destinationAddress != destinationAddress {
            nature.insert(.destinationAddress)
        }

        if other.broadcastAddress != broadcastAddress {
            nature.insert(.broadcastAddress)
        }

        if other.flags != flags {
            nature.insert(.flags)
        }

        return nature
    }


    /// Guesstimates how similar the two ``NetworkInterface``s are.
    ///
    /// This is a fuzzy heuristic.  There doesn't appear to be a deterministic way to tell if two instances are actually related across time, because any or all their attributes can change, and they have no persistent, unique identifier.
    ///
    /// See the comments in the implementation for rationale on heuristic weightings.
    ///
    /// - Returns: An estimated similarity score where higher values mean more similar, or nil if the two are definitively not similar (e.g. different address families entirely).
    func similarityScore(versus other: NetworkInterface) -> Int? {
        // Caching these two for efficiency - they're not completely trivial getters.
        let myFamily = addressFamily
        let otherFamily = other.addressFamily

        guard name == other.name && (nil == myFamily || nil == otherFamily || myFamily != otherFamily) else {
            return nil // Always assume mismatched hardware interfaces or address families are non-matches.
        }

        // Like above, caching these four for efficiency too.
        let myAddress = address
        let myNetmask = netmask
        let myBroadcast = broadcastAddress
        let myDestination = destinationAddress

        return (
            // Always assume address matches are in a class of their own, better candidates than any non-address matches.
            (nil != myAddress && myAddress == other.address ? 100 : 0)

            // Matching destination addresses is fairly suggestive, as it's unlikely to have multiple interfaces with the same destination.
            + (nil != myDestination && myDestination == other.destinationAddress ? 20 : 0)

            // Netmask and flags are weak signals, but can be tie-breakers.
            + (nil != myNetmask && myNetmask == other.netmask ? 10 : 0)
            + (flags == other.flags ? 10 : 0)

            // Lowest consideration since they're fairly generic and likely to coincidentally match, plus it's often only present when netmask is too, and the netmask already factored in.
            + (nil != myBroadcast && myBroadcast == other.broadcastAddress ? 5 : 0)
        )
    }
}

extension NetworkInterface.Change.ModificationNature: CaseIterable {
    public static var allCases: [Self] = [.address,
                                          .netmask,
                                          .broadcastAddress,
                                          .destinationAddress,
                                          .flags]
}

extension NetworkInterface.Change.ModificationNature: Hashable {}

extension NetworkInterface.Change.ModificationNature: CustomStringConvertible {
    private static let names: [Self: String] = [.address: "Address",
                                                .netmask: "Netmask",
                                                .broadcastAddress: "Broadcast Address",
                                                .destinationAddress: "Destination Address",
                                                .flags: "Flags"]

    public var description: String {
        let knownFlagBits = Self.allCases.filter { self.contains($0) }

        return (Set(knownFlagBits.map { Self.names[$0] ?? "Unknown" }).sorted()
                + self.subtracting(Self(knownFlagBits)).rawValue.bits.map { "0x" + String($0, radix: 16) })
                .joined(separator: ", ")
    }
}
