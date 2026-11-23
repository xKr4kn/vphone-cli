import CryptoKit
import Foundation

/// One of the two host-side kernel slots. The slot holds the full Preboot
/// kernelcache IMG4, so a rollback puts back exactly what booted before.
public enum FirmwareBootSlot: String, Codable, Sendable, CaseIterable {
    case a
    case b

    public var other: Self {
        self == .a ? .b : .a
    }
}

/// A content-addressed kernel artifact.
public struct FirmwareBootArtifact: Codable, Sendable, Hashable {
    public let sha256: String
    public let size: Int

    public init(sha256: String, size: Int) {
        self.sha256 = sha256
        self.size = size
    }

    public init(data: Data) {
        sha256 = FirmwareBootAdmission.sha256(data)
        size = data.count
    }
}

/// State of one slot.
public enum FirmwareBootSlotState: String, Codable, Sendable {
    case active
    case standby
    case candidate
    case bad
}

/// One slot's artifact and what its kernel was built with.
public struct FirmwareBootSlotRecord: Codable, Sendable, Hashable {
    public var artifact: FirmwareBootArtifact
    public var state: FirmwareBootSlotState
    public var enabledKernelPatches: [String]

    public init(
        artifact: FirmwareBootArtifact,
        state: FirmwareBootSlotState,
        enabledKernelPatches: [String],
    ) {
        self.artifact = artifact
        self.state = state
        self.enabledKernelPatches = enabledKernelPatches
    }
}

/// A candidate installed into Preboot but not yet proven by a boot.
public struct FirmwareBootPending: Codable, Sendable, Hashable {
    public var slot: FirmwareBootSlot
    public var kernelSHA256: String
    public var previousActive: FirmwareBootSlot
    public var enabledKernelPatches: [String]
    /// False between the state write and the Preboot write; a commit before
    /// this becomes true would promote a kernel that never landed.
    public var installed: Bool
    public var createdAt: Date

    public init(
        slot: FirmwareBootSlot,
        kernelSHA256: String,
        previousActive: FirmwareBootSlot,
        enabledKernelPatches: [String],
        installed: Bool,
        createdAt: Date,
    ) {
        self.slot = slot
        self.kernelSHA256 = kernelSHA256
        self.previousActive = previousActive
        self.enabledKernelPatches = enabledKernelPatches
        self.installed = installed
        self.createdAt = createdAt
    }
}

/// The persisted boot transaction.
public struct FirmwareBootState: Codable, Sendable, Hashable {
    public var active: FirmwareBootSlot
    public var a: FirmwareBootSlotRecord
    public var b: FirmwareBootSlotRecord
    public var pending: FirmwareBootPending?
    public var failedAttempts: Int

    public init(
        active: FirmwareBootSlot,
        a: FirmwareBootSlotRecord,
        b: FirmwareBootSlotRecord,
        pending: FirmwareBootPending?,
        failedAttempts: Int,
    ) {
        self.active = active
        self.a = a
        self.b = b
        self.pending = pending
        self.failedAttempts = failedAttempts
    }

    public func slot(_ slot: FirmwareBootSlot) -> FirmwareBootSlotRecord {
        slot == .a ? a : b
    }

    public mutating func setSlot(_ slot: FirmwareBootSlot, _ record: FirmwareBootSlotRecord) {
        if slot == .a {
            a = record
        } else {
            b = record
        }
    }
}

/// A plan the installer can execute: write the active snapshot if needed,
/// write the candidate, write the state, then replace Preboot.
public struct FirmwareBootPlan: Sendable, Hashable {
    public var state: FirmwareBootState
    public var target: FirmwareBootSlot
    public var activeArtifact: FirmwareBootArtifact
    public var candidateArtifact: FirmwareBootArtifact
    public var writeActive: Bool
    public var writeCandidate: Bool

    public init(
        state: FirmwareBootState,
        target: FirmwareBootSlot,
        activeArtifact: FirmwareBootArtifact,
        candidateArtifact: FirmwareBootArtifact,
        writeActive: Bool,
        writeCandidate: Bool,
    ) {
        self.state = state
        self.target = target
        self.activeArtifact = activeArtifact
        self.candidateArtifact = candidateArtifact
        self.writeActive = writeActive
        self.writeCandidate = writeCandidate
    }
}

/// The result a boot produced.
public enum FirmwareBootResult: String, Codable, Sendable {
    case booted
    case panicked
    case watchdogTimeout
}

/// Evidence of one commit or rollback.
public struct FirmwareBootReceipt: Codable, Sendable, Hashable {
    public var slot: FirmwareBootSlot
    public var kernelSHA256: String
    public var result: FirmwareBootResult
    public var evidence: String
    public var at: Date

    public init(
        slot: FirmwareBootSlot,
        kernelSHA256: String,
        result: FirmwareBootResult,
        evidence: String,
        at: Date,
    ) {
        self.slot = slot
        self.kernelSHA256 = kernelSHA256
        self.result = result
        self.evidence = evidence
        self.at = at
    }
}

/// Boot admission failures.
public enum FirmwareBootError: Error, LocalizedError, Equatable {
    case pendingBoot(FirmwareBootSlot)
    case staleActive(expected: String, actual: String)
    case noChange
    case noPendingBoot
    case bootNotInstalled
    case invalidRollbackResult
    case invalidState(String)
    case stateEncoding(String)

    public var errorDescription: String? {
        switch self {
        case .pendingBoot(let slot):
            "A kernel update is already pending in slot \(slot.rawValue.uppercased()). Boot it and commit, or roll it back, before changing the kernel again."
        case .staleActive(let expected, let actual):
            "The Preboot kernelcache does not match the recorded active slot. Expected \(expected.prefix(12))…, found \(actual.prefix(12))…. Reconcile the VM before updating it."
        case .noChange:
            "The candidate kernelcache already matches the Preboot kernelcache."
        case .noPendingBoot:
            "There is no pending kernel update to finish."
        case .bootNotInstalled:
            "The candidate has not been written into Preboot yet; refusing to commit it."
        case .invalidRollbackResult:
            "A booted candidate must be committed, not rolled back."
        case .invalidState(let detail):
            "The boot state is inconsistent: \(detail)"
        case .stateEncoding(let detail):
            "The boot state could not be encoded or decoded: \(detail)"
        }
    }
}

/// Pure state machine for the A/B kernel transaction. File I/O and Preboot
/// writes stay in the installer; the commit/rollback decisions are here.
public enum FirmwareBootAdmission {
    public static let stateFileName = "BootState.plist"
    public static let receiptFileName = "BootReceipt.plist"
    public static let slotsDirectoryName = "BootSlots"

    public static func slotFileName(_ slot: FirmwareBootSlot) -> String {
        "\(slot.rawValue).img4"
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Plan the first update (no state yet) or the next update.
    ///
    /// - `activeEnabled`: the kernel patches the currently booting kernel was
    ///   built with, recorded only on the first snapshot.
    /// - `candidateEnabled`: the patches the new kernelcache was built with.
    public static func plan(
        state: FirmwareBootState?,
        current: Data,
        candidate: Data,
        activeEnabled: [String],
        candidateEnabled: [String],
        now: Date,
    ) throws -> FirmwareBootPlan {
        let activeArtifact = FirmwareBootArtifact(data: current)
        let candidateArtifact = FirmwareBootArtifact(data: candidate)
        guard activeArtifact.sha256 != candidateArtifact.sha256 else {
            throw FirmwareBootError.noChange
        }

        if let state {
            if let pending = state.pending {
                throw FirmwareBootError.pendingBoot(pending.slot)
            }
            let activeRecord = state.slot(state.active)
            guard activeRecord.artifact.sha256 == activeArtifact.sha256 else {
                throw FirmwareBootError.staleActive(
                    expected: activeRecord.artifact.sha256,
                    actual: activeArtifact.sha256,
                )
            }
            let target = state.active.other
            var next = state
            next.setSlot(
                target,
                FirmwareBootSlotRecord(
                    artifact: candidateArtifact,
                    state: .candidate,
                    enabledKernelPatches: candidateEnabled.sorted(),
                ),
            )
            next.pending = FirmwareBootPending(
                slot: target,
                kernelSHA256: candidateArtifact.sha256,
                previousActive: state.active,
                enabledKernelPatches: candidateEnabled.sorted(),
                installed: false,
                createdAt: now,
            )
            return FirmwareBootPlan(
                state: next,
                target: target,
                activeArtifact: activeRecord.artifact,
                candidateArtifact: candidateArtifact,
                writeActive: false,
                writeCandidate: true,
            )
        }

        let a = FirmwareBootSlotRecord(
            artifact: activeArtifact,
            state: .active,
            enabledKernelPatches: activeEnabled.sorted(),
        )
        let b = FirmwareBootSlotRecord(
            artifact: candidateArtifact,
            state: .candidate,
            enabledKernelPatches: candidateEnabled.sorted(),
        )
        let pending = FirmwareBootPending(
            slot: .b,
            kernelSHA256: candidateArtifact.sha256,
            previousActive: .a,
            enabledKernelPatches: candidateEnabled.sorted(),
            installed: false,
            createdAt: now,
        )
        let state = FirmwareBootState(
            active: .a,
            a: a,
            b: b,
            pending: pending,
            failedAttempts: 0,
        )
        return FirmwareBootPlan(
            state: state,
            target: .b,
            activeArtifact: activeArtifact,
            candidateArtifact: candidateArtifact,
            writeActive: true,
            writeCandidate: true,
        )
    }

    /// Mark the candidate as written into Preboot. Call only after the
    /// kernelcache replacement succeeded.
    public static func markInstalled(
        state: FirmwareBootState,
        now _: Date,
    ) throws -> FirmwareBootState {
        guard var pending = state.pending else {
            throw FirmwareBootError.noPendingBoot
        }
        pending.installed = true
        var next = state
        next.pending = pending
        return next
    }

    /// Promote the candidate after the guest booted and answered.
    public static func commit(
        state: FirmwareBootState,
        evidence: String,
        now: Date,
    ) throws -> (state: FirmwareBootState, receipt: FirmwareBootReceipt) {
        guard let pending = state.pending else {
            throw FirmwareBootError.noPendingBoot
        }
        guard pending.installed else {
            throw FirmwareBootError.bootNotInstalled
        }
        guard pending.slot != state.active else {
            throw FirmwareBootError.invalidState("the pending slot is already active")
        }
        var next = state
        var candidate = next.slot(pending.slot)
        candidate.state = .active
        next.setSlot(pending.slot, candidate)
        var previous = next.slot(next.active)
        previous.state = .standby
        next.setSlot(next.active, previous)
        next.active = pending.slot
        next.pending = nil
        next.failedAttempts = 0
        let receipt = FirmwareBootReceipt(
            slot: pending.slot,
            kernelSHA256: pending.kernelSHA256,
            result: .booted,
            evidence: evidence,
            at: now,
        )
        return (next, receipt)
    }

    /// Keep the active slot and mark the candidate bad.
    public static func rollback(
        state: FirmwareBootState,
        result: FirmwareBootResult,
        evidence: String,
        now: Date,
    ) throws -> (state: FirmwareBootState, receipt: FirmwareBootReceipt) {
        guard let pending = state.pending else {
            throw FirmwareBootError.noPendingBoot
        }
        guard result != .booted else {
            throw FirmwareBootError.invalidRollbackResult
        }
        var next = state
        var candidate = next.slot(pending.slot)
        candidate.state = .bad
        next.setSlot(pending.slot, candidate)
        next.pending = nil
        next.failedAttempts = max(0, state.failedAttempts) + 1
        let receipt = FirmwareBootReceipt(
            slot: pending.slot,
            kernelSHA256: pending.kernelSHA256,
            result: result,
            evidence: evidence,
            at: now,
        )
        return (next, receipt)
    }

    public static func encode(state: FirmwareBootState) throws -> Data {
        do {
            return try PropertyListEncoder().encode(state)
        } catch {
            throw FirmwareBootError.stateEncoding(error.localizedDescription)
        }
    }

    public static func decodeState(_ data: Data) throws -> FirmwareBootState {
        do {
            return try PropertyListDecoder().decode(FirmwareBootState.self, from: data)
        } catch {
            throw FirmwareBootError.stateEncoding(error.localizedDescription)
        }
    }

    public static func encodeReceipt(_ receipt: FirmwareBootReceipt) throws -> Data {
        do {
            return try PropertyListEncoder().encode(receipt)
        } catch {
            throw FirmwareBootError.stateEncoding(error.localizedDescription)
        }
    }
}
