import CoreTelephony
import Foundation
import Network

/// Nigerian carriers that have a pipeline-generated cellular profile
/// (`scripts/generate-cellular-mobileconfig.sh` writes one `com.apple.cellular` payload per case).
enum Carrier: String, Codable, CaseIterable, Identifiable {
    case airtel
    case mtn
    case glo
    case nineMobile = "9mobile"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airtel: return "Airtel"
        case .mtn: return "MTN"
        case .glo: return "Glo"
        case .nineMobile: return "9mobile"
        }
    }

    /// APN written into the profile; must match the CI script.
    var apn: String {
        switch self {
        case .airtel: return "internet.ng.airtel.com"
        case .mtn: return "web.gprs.mtnn.net"
        case .glo: return "gloflat"
        case .nineMobile: return "9mobile"
        }
    }

    /// APN user name the carrier publishes for manual configuration, nil when the network accepts
    /// the APN without a login. Written into the profile by the CI script; keep both in step.
    /// Airtel Nigeria refuses the data context without its login, which left Airtel SIMs with no
    /// internet and nothing for the profile verifier to see.
    var apnUsername: String? {
        switch self {
        case .airtel: return "internet"
        case .mtn, .glo, .nineMobile: return nil
        }
    }

    /// APN password paired with `apnUsername`.
    var apnPassword: String? {
        switch self {
        case .airtel: return "internet"
        case .mtn, .glo, .nineMobile: return nil
        }
    }

    /// `user / password` for the Carrier Profile screen, or "None".
    var apnLoginSummary: String {
        guard let apnUsername, let apnPassword else { return "None" }
        return "\(apnUsername) / \(apnPassword)"
    }

    /// File name produced by the CI script and shipped in the `build_ipa` artifact.
    var profileFileName: String { "\(title)-Cellular-Proxy.mobileconfig" }

    /// Display name of the unified bundle that carries every carrier's APN in one profile.
    static let universalTitle = "Universal"

    /// File name of the unified bundle written by `scripts/generate-cellular-mobileconfig.sh`
    /// (`write_universal_profile`). One `com.apple.cellular` payload whose APNs array lists all four
    /// carriers, so a single install covers every regional network; keep the two in step.
    static let universalProfileFileName = "\(universalTitle)-Cellular-Proxy.mobileconfig"

    /// Mobile Country Code shared by every Nigerian network.
    static let nigeriaMCC = "621"

    /// Mobile Network Codes registered to the carrier (ITU / MCC-MNC list).
    var mobileNetworkCodes: [String] {
        switch self {
        case .airtel: return ["20"]
        case .mtn: return ["30"]
        case .glo: return ["50"]
        case .nineMobile: return ["60"]
        }
    }

    /// Lower-case fragments of the carrier name reported by the SIM.
    var nameKeywords: [String] {
        switch self {
        case .airtel: return ["airtel", "zain"]
        case .mtn: return ["mtn"]
        case .glo: return ["glo", "globacom"]
        case .nineMobile: return ["9mobile", "etisalat"]
        }
    }

    /// Carrier for an MCC/MNC pair, or nil when the pair is not one of the four networks.
    static func match(mcc: String?, mnc: String?) -> Carrier? {
        guard let mcc, let mnc, Int(mcc) == Int(nigeriaMCC), let code = Int(mnc) else { return nil }
        return allCases.first { carrier in
            carrier.mobileNetworkCodes.contains { Int($0) == code }
        }
    }

    /// Carrier whose name fragments appear in `carrierName`, or nil.
    static func match(carrierName: String?) -> Carrier? {
        guard let name = carrierName?.lowercased(), !name.isEmpty, name != "--" else { return nil }
        return allCases.first { carrier in
            carrier.nameKeywords.contains { name.contains($0) }
        }
    }
}

/// What CoreTelephony reported about the data SIM and which carrier it maps to.
struct CarrierDetection: Equatable {
    var hasSIM = false
    var carrierName: String?
    var mcc: String?
    var mnc: String?
    var radioTechnology: String?
    var carrier: Carrier?
    /// iOS 16.4 and later hand every app the placeholder values 65535 / "--" instead of the real
    /// SIM data, so detection has to fall back to the manual carrier picker.
    var isPlaceholder = false

    var codeText: String {
        guard let mcc, let mnc else { return "Unavailable" }
        return "\(mcc) / \(mnc)"
    }

    /// One line for the Home card.
    var summary: String {
        if !hasSIM { return "No SIM detected" }
        if let carrier { return "\(carrier.title) SIM detected" }
        if isPlaceholder { return "iOS hides the SIM codes from apps" }
        return "Unknown network (\(codeText))"
    }
}

/// Reads the active SIM through `CTTelephonyNetworkInfo` and maps it to a `Carrier`.
enum CarrierDetector {
    /// Value CoreTelephony returns for MCC and MNC on iOS 16.4+ instead of the real codes.
    static let placeholderCode = "65535"

    static func detect() -> CarrierDetection {
        let info = CTTelephonyNetworkInfo()
        let providers = info.serviceSubscriberCellularProviders ?? [:]
        let radios = info.serviceCurrentRadioAccessTechnology ?? [:]

        var keys = providers.keys.sorted()
        if let data = info.dataServiceIdentifier, let index = keys.firstIndex(of: data) {
            keys.remove(at: index)
            keys.insert(data, at: 0)
        }
        guard !keys.isEmpty else { return CarrierDetection() }

        // Prefer a SIM with real codes; otherwise the data SIM.
        let chosen = keys.first { isReal(providers[$0]) } ?? keys[0]
        let provider = providers[chosen]

        var detection = CarrierDetection(hasSIM: true)
        detection.carrierName = clean(provider?.carrierName)
        detection.mcc = clean(provider?.mobileCountryCode)
        detection.mnc = clean(provider?.mobileNetworkCode)
        detection.radioTechnology = radios[chosen].map(radioName)
        detection.isPlaceholder = detection.mcc == placeholderCode || detection.mnc == placeholderCode
        if detection.isPlaceholder {
            detection.mcc = nil
            detection.mnc = nil
        }
        detection.carrier = Carrier.match(mcc: detection.mcc, mnc: detection.mnc)
            ?? Carrier.match(carrierName: detection.carrierName)
            ?? CarrierDetector.matchCellularIP()   // iOS 16.4+ fallback: IP-range heuristic
        return detection
    }

    /// Tier-3 detection: match the cellular interface IP against known Nigerian carrier
    /// public IP blocks. Works on every iOS version because it reads the interface address,
    /// not CoreTelephony. Returns nil when the device is not on cellular or no block matches.
    static func matchCellularIP() -> Carrier? {
        guard let ip = NetworkInterfaces.ipv4Address(of: .cellular) else { return nil }
        guard let addr = IPv4Address(ip) else { return nil }
        let n = addr.rawValue.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        // Nigerian carrier public IP allocations (CGNAT-aware, major blocks only).
        // Format: (network_uint32, prefix_length)
        let blocks: [(UInt32, UInt32, Carrier)] = [
            // Airtel Nigeria
            (ipToUInt32(41, 58, 0, 0),   16, .airtel),
            (ipToUInt32(41, 184, 0, 0),  16, .airtel),
            // MTN Nigeria
            (ipToUInt32(41, 203, 0, 0),  16, .mtn),
            (ipToUInt32(197, 210, 0, 0), 16, .mtn),
            // Glo Nigeria
            (ipToUInt32(41, 73, 0, 0),   16, .glo),
            (ipToUInt32(197, 255, 0, 0), 16, .glo),
            // 9mobile (Etisalat) Nigeria
            (ipToUInt32(41, 63, 0, 0),   16, .nineMobile),
            (ipToUInt32(197, 157, 0, 0), 16, .nineMobile),
        ]
        for (network, prefix, carrier) in blocks {
            let mask: UInt32 = prefix == 32 ? 0xFFFF_FFFF : ~(0xFFFF_FFFF >> prefix)
            if n & mask == network & mask { return carrier }
        }
        return nil
    }

    private static func ipToUInt32(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        (a << 24) | (b << 16) | (c << 8) | d
    }

    private static func isReal(_ carrier: CTCarrier?) -> Bool {
        guard let carrier, let mcc = carrier.mobileCountryCode, let mnc = carrier.mobileNetworkCode else { return false }
        return mcc != placeholderCode && mnc != placeholderCode && !mcc.isEmpty && !mnc.isEmpty
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "--" else {
            return nil
        }
        return value
    }

    /// `CTRadioAccessTechnologyLTE` -> `LTE`, the 5G constants -> `5G`.
    private static func radioName(_ constant: String) -> String {
        let name = constant.replacingOccurrences(of: "CTRadioAccessTechnology", with: "")
        switch name {
        case "NRNSA", "NR": return "5G"
        case "WCDMA", "HSDPA", "HSUPA": return "3G (\(name))"
        case "GPRS", "Edge": return "2G (\(name))"
        default: return name
        }
    }
}
