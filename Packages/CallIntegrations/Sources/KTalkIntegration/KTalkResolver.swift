import Foundation
import CallIntegrations

struct KTalkReading: Equatable, Sendable {
    var participation: CallParticipation
    var call: CallInfo? = nil
    var emptyWindow = false
}

enum KTalkResolver {
    static func resolve(cdp: KTalkReading, accessibility: KTalkReading) -> (KTalkReading, CallObservationSource?) {
        if cdp.participation != .unknown { return (cdp, .application) }
        if accessibility.participation != .unknown { return (accessibility, .accessibility) }
        return (KTalkReading(participation: .unknown), nil)
    }
}
