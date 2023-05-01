#if !canImport(Network)
#warning("NetworkInterfaceChangeMonitoring requires the Network module, which is not available (it is a propertiary Apple module only available on Apple platforms, not Linux or Windows).")
#else

@preconcurrency import Dispatch
import FoundationExtensions
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
    /// Changes are reported as a simple structure - ``Change`` - that provides an indication not only of what ``NetworkInterface`` changed by in what manner; whether it is newly added, just removed, or modified (with indications of which fields were modified).
    ///
    /// Note that some modifications may be reported as first a removal and then an addition.  This reflects how the underlying system actually manages these interfaces, sometimes, even for seemingly trivial modifications like changing the IP address on an interface.
    ///
    /// Note that there may be a delay between the actual changes occuring and them being reported (even if `coalescingPeriod` is 0).  This function relies on the ``Network/NWPathMonitor`` functionality from Apple, and while typically Apple's library provides notification of changes immediately, at other times it takes longer.  There is no defined upper bound on this latency, and delays on the order of minutes have been observed in practice.
    ///
    /// - Parameters:
    ///   - coalescingPeriod: How long to wait, after detecting a change, before actually reporting it.  A negative or zero value means no wait.
    ///
    ///     Having a coalescing period allows multiple changes to be coalesced into one, which may improve the semantic accuracy of the reported changes (particularly regarding recognising modifications properly, as opposed to a removal followed by an addition).  The downsides are that it delays change reports, and it may cause some changes to be missed entirely (e.g. addition followed by removal).
    ///
    ///     The ideal value is use-case specific.  If you don't care whether you see changes as single modifications vs pairs of adds and removes, a value of zero (the default) is the best.  Otherwise, a single second is helpful but typically not sufficient to coalesce all modifications.  Several seconds is usually sufficient, but there can still be exceptions.  Consider what the delay means for your use-case - e.g. if it takes a while to switch wifi networks, during which time the internet is not accessible, are you satisfied with eventually just receiving notification of a change in wifi settings or do you want to know more immediately that access via wifi has been [temporarily] lost?
    ///
    /// - Returns: An endless stream of change events.  Awaiting its next value will block (as needed) until the next change occurs.
    static func changes(coalescingPeriod: Int = 0) -> AsyncThrowingStream<Change, Error> {
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

            let queue = DispatchQueue(label: "NetworkInterface.changes")
            let monitor = NWPathMonitor()

            // Use of queue-specific storage is a bit of a hacky workaround to the Swift compiler not being able to correctly reason about shared state and dispatch queues.
            //
            // It's basically just hiding [from the compiler] the pointer to the live 'enqueued handler' task, rather than storing it a local variable.
            //
            // Possibly there'll be a way, in future, to drop Dispatch and use "pure" Swift (i.e. tasks, actors, etc), which will presumably not have issues with incorrect deductions by the compiler, but I couldn't find any sane way to implement this simple pattern with Task and/or actors in Swift 5.8.
            let enqueuedHandlerKey = DispatchSpecificKey<DispatchWorkItem>()

            let reportAnyChanges = {
                //print("Reporting changes (if any)…")

                let currentInterfaces: Set<NetworkInterface>

                do {
                    currentInterfaces = Set(try NetworkInterface.all)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let newOrChangedInterfaces = currentInterfaces.subtracting(lastInterfaces)
                var goneOrChangedInterfaces = lastInterfaces.subtracting(currentInterfaces)

                for interface in newOrChangedInterfaces {
                    //print("Candidate origins of \(interface):")

                    let bestMatch = goneOrChangedInterfaces.reduce(nil) { bestSoFar, candidate -> (Int, NetworkInterface)? in
                        let candidateScore = interface.similarityScore(versus: candidate)

                        //print("\tScore \(candidateScore.orNilString) for \(candidate)")

                        guard let candidateScore else {
                            return bestSoFar

                        }

                        guard let bestSoFar, bestSoFar.0 >= candidateScore else {
                            return (candidateScore, candidate)
                        }

                        return bestSoFar
                    }?.1

                    if let bestMatch {
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
            }

            monitor.pathUpdateHandler = { _ in
                //print("NWPathMonitor reported a change.")

                if 0 >= coalescingPeriod {
                    reportAnyChanges()
                } else {
                    guard nil == queue.getSpecific(key: enqueuedHandlerKey) else {
                        //print("Change reporting already scheduled.")
                        return
                    }

                    //print("Scheduling change report for \(coalescingPeriod) seconds from now.")

                    let task = DispatchWorkItem() {
                        reportAnyChanges()
                        queue.setSpecific(key: enqueuedHandlerKey, value: nil)
                    }

                    queue.setSpecific(key: enqueuedHandlerKey, value: task)
                    queue.asyncAfter(deadline: .now().advanced(by: .seconds(coalescingPeriod)),
                                     execute: task)
                }
            }

            continuation.onTermination = { @Sendable _ in
                monitor.cancel()

                queue.sync {
                    if let enqueuedHandlerTask = queue.getSpecific(key: enqueuedHandlerKey) {
                        enqueuedHandlerTask.cancel()
                    }
                }
            }

            monitor.start(queue: queue)
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
    public static let allCases: [Self] = [.address,
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
#endif
