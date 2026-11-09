// SPDX-License-Identifier: Apache-2.0

import Foundation
import ShadowKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The real Apple on-device model behind `OnDeviceProvider` (R2). On a toolchain without FoundationModels it still
/// builds and reports the device as not eligible.
struct FoundationModelsModel: OnDeviceModel {
    #if canImport(FoundationModels)
    func status() -> AppleStatus {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .modelNotReady
        }
    }

    func respond(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        LLMStream.make { out in
            let session = LanguageModelSession(instructions: system)
            var cumulative = CumulativeDelta()
            do {
                for try await snapshot in session.streamResponse(to: user) {
                    let delta = cumulative.delta(from: snapshot.content)
                    if !delta.isEmpty { out.yield(delta) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw OnDeviceErrorMapper.map(String(reflecting: error))
            }
        }
    }
    #else
    func status() -> AppleStatus { .deviceNotEligible }
    func respond(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError(.unavailable, detail: "FoundationModels not in this build")) }
    }
    #endif
}
