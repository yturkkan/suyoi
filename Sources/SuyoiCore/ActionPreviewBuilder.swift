import Foundation

public struct ActionPreviewBuilder: Sendable {
    public init() {}

    public func build(candidates: [CleanupCandidate], assessments: [String: SafetyAssessment], now: Date = Date()) -> ActionPreview {
        let eligible = candidates.filter { candidate in
            guard let assessment = assessments[candidate.id], assessment.candidateID == candidate.id,
                  assessment.isReviewableForTrash, assessment.blockedReasons.isEmpty, assessment.usage == .clear,
                  !candidate.partial, candidate.fileIdentity != nil else { return false }
            switch assessment.regenerability { case .lockfileVerified, .cacheDirectory: return true; case .unverified: return false }
        }
        func sum(_ values: [Int64]) -> Int64 {
            values.reduce(0) { total, value in
                let amount = max(0, value)
                return total > Int64.max - amount ? Int64.max : total + amount
            }
        }
        let allocated = eligible.compactMap { $0.allocatedBytes }
        return ActionPreview(id: UUID().uuidString, createdAt: now, candidates: candidates, assessments: assessments,
                             blockedCount: candidates.count - eligible.count, eligibleCount: eligible.count,
                             totalLogicalBytes: sum(eligible.map { $0.bytes }),
                             totalAllocatedBytes: allocated.count == eligible.count ? sum(allocated) : nil)
    }
}
