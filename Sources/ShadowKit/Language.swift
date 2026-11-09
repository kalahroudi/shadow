// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The language choices in the popover and Settings (R11).
public enum Language: String, CaseIterable, Sendable, Codable {
    case auto, english, spanish, german, french, japanese

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .japanese: "Japanese"
        }
    }

    /// The fixed locale for a concrete choice; nil for Auto.
    public var fixedLocale: Locale? {
        switch self {
        case .auto: nil
        case .english: Locale(identifier: "en-US")
        case .spanish: Locale(identifier: "es-ES")
        case .german: Locale(identifier: "de-DE")
        case .french: Locale(identifier: "fr-FR")
        case .japanese: Locale(identifier: "ja-JP")
        }
    }

    public static let fallback = Locale(identifier: "en-US")

    /// Concrete choices map directly; Auto picks the first preferred language whose language code is supported.
    public func resolve(preferred: [String] = Locale.preferredLanguages, supported: [Locale]) -> Locale {
        if let fixed = fixedLocale { return fixed }
        for id in preferred {
            let wanted = Locale(identifier: id)
            if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) { return exact }
            if let code = wanted.language.languageCode,
               let match = supported.first(where: { $0.language.languageCode == code }) { return match }
        }
        return Self.fallback
    }
}
