import Foundation
import Testing

@testable import FirmwarePatcher

@Suite("Firmware boot admission")
struct FirmwareBootAdmissionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func bytes(_ value: UInt8) -> Data {
        Data(repeating: value, count: 32)
    }

    private func firstPlan() throws -> FirmwareBootPlan {
        try FirmwareBootAdmission.plan(
            state: nil,
            current: bytes(0xAA),
            candidate: bytes(0xBB),
            activeEnabled: ["kernel-active"],
            candidateEnabled: ["kernel-candidate"],
            now: now,
        )
    }

    private func installedPlan() throws -> FirmwareBootPlan {
        let plan = try firstPlan()
        let state = try FirmwareBootAdmission.markInstalled(state: plan.state, now: now)
        return FirmwareBootPlan(
            state: state,
            target: plan.target,
            activeArtifact: plan.activeArtifact,
            candidateArtifact: plan.candidateArtifact,
            writeActive: plan.writeActive,
            writeCandidate: plan.writeCandidate,
        )
    }

    private func committedState() throws -> FirmwareBootState {
        let plan = try installedPlan()
        return try FirmwareBootAdmission.commit(
            state: plan.state,
            evidence: "vphoned answered",
            now: now,
        ).state
    }

    @Test
    func `sha256 is lowercase hex`() {
        #expect(
            FirmwareBootAdmission.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test
    func `first plan snapshots the active kernel and writes the candidate to the inactive slot`()
        throws
    {
        let plan = try firstPlan()
        #expect(plan.target == .b)
        #expect(plan.writeActive)
        #expect(plan.writeCandidate)
        #expect(plan.state.active == .a)
        #expect(plan.state.a.state == .active)
        #expect(plan.state.a.artifact.sha256 == plan.activeArtifact.sha256)
        #expect(plan.state.a.enabledKernelPatches == ["kernel-active"])
        #expect(plan.state.b.state == .candidate)
        #expect(plan.state.b.artifact.sha256 == plan.candidateArtifact.sha256)
        #expect(plan.state.b.enabledKernelPatches == ["kernel-candidate"])
        #expect(plan.state.pending?.slot == .b)
        #expect(plan.state.pending?.installed == false)
    }

    @Test
    func `a pending boot blocks another update`() throws {
        let plan = try firstPlan()
        do {
            _ = try FirmwareBootAdmission.plan(
                state: plan.state,
                current: bytes(0xAA),
                candidate: bytes(0xCC),
                activeEnabled: [],
                candidateEnabled: [],
                now: now,
            )
            #expect(Bool(false), "a pending boot must not be overwritten")
        } catch let error as FirmwareBootError {
            #expect(error == .pendingBoot(.b))
        }
    }

    @Test
    func `a stale active artifact blocks the update`() throws {
        let committed = try committedState()
        do {
            _ = try FirmwareBootAdmission.plan(
                state: committed,
                current: bytes(0xAA),
                candidate: bytes(0xCC),
                activeEnabled: [],
                candidateEnabled: [],
                now: now,
            )
            #expect(Bool(false), "the state names a different active kernel")
        } catch let error as FirmwareBootError {
            #expect(
                error
                    == .staleActive(
                        expected: FirmwareBootAdmission.sha256(bytes(0xBB)),
                        actual: FirmwareBootAdmission.sha256(bytes(0xAA)),
                    ))
        }
    }

    @Test
    func `an unchanged candidate is refused`() throws {
        do {
            _ = try FirmwareBootAdmission.plan(
                state: nil,
                current: bytes(0xAA),
                candidate: bytes(0xAA),
                activeEnabled: [],
                candidateEnabled: [],
                now: now,
            )
            #expect(Bool(false), "an identical candidate is not an update")
        } catch let error as FirmwareBootError {
            #expect(error == .noChange)
        }
    }

    @Test
    func
        `after a commit the next plan targets the other slot without rewriting the active artifact`()
        throws
    {
        let committed = try committedState()
        let plan = try FirmwareBootAdmission.plan(
            state: committed,
            current: bytes(0xBB),
            candidate: bytes(0xCC),
            activeEnabled: [],
            candidateEnabled: ["kernel-next"],
            now: now,
        )
        #expect(plan.target == .a)
        #expect(!plan.writeActive)
        #expect(plan.writeCandidate)
        #expect(plan.state.a.state == .candidate)
        #expect(plan.state.b.state == .active)
        #expect(plan.state.pending?.slot == .a)
    }

    @Test
    func `commit requires an installed pending boot`() throws {
        let plan = try firstPlan()
        do {
            _ = try FirmwareBootAdmission.commit(
                state: plan.state,
                evidence: "too early",
                now: now,
            )
            #expect(Bool(false), "commit before the candidate landed must fail")
        } catch let error as FirmwareBootError {
            #expect(error == .bootNotInstalled)
        }
    }

    @Test
    func `commit without a pending boot fails`() throws {
        let committed = try committedState()
        do {
            _ = try FirmwareBootAdmission.commit(
                state: committed,
                evidence: "again",
                now: now,
            )
            #expect(Bool(false), "there is nothing pending")
        } catch let error as FirmwareBootError {
            #expect(error == .noPendingBoot)
        }
    }

    @Test
    func `commit promotes the candidate and keeps the previous slot as standby`() throws {
        let plan = try installedPlan()
        let (state, receipt) = try FirmwareBootAdmission.commit(
            state: plan.state,
            evidence: "vphoned answered",
            now: now,
        )
        #expect(state.active == .b)
        #expect(state.a.state == .standby)
        #expect(state.b.state == .active)
        #expect(state.pending == nil)
        #expect(state.failedAttempts == 0)
        #expect(receipt.slot == .b)
        #expect(receipt.result == .booted)
        #expect(receipt.evidence == "vphoned answered")
    }

    @Test
    func `rollback keeps the active slot and marks the candidate bad`() throws {
        let plan = try installedPlan()
        let (state, receipt) = try FirmwareBootAdmission.rollback(
            state: plan.state,
            result: .panicked,
            evidence: "panic: launchd",
            now: now,
        )
        #expect(state.active == .a)
        #expect(state.a.state == .active)
        #expect(state.b.state == .bad)
        #expect(state.pending == nil)
        #expect(state.failedAttempts == 1)
        #expect(receipt.result == .panicked)
    }

    @Test
    func `rollback refuses a booted receipt`() throws {
        let plan = try installedPlan()
        do {
            _ = try FirmwareBootAdmission.rollback(
                state: plan.state,
                result: .booted,
                evidence: "wrong",
                now: now,
            )
            #expect(Bool(false), "a booted candidate is committed, not rolled back")
        } catch let error as FirmwareBootError {
            #expect(error == .invalidRollbackResult)
        }
    }

    @Test
    func `reusing a bad slot is allowed and resets it to candidate`() throws {
        var state = try committedState()
        state.a.state = .bad
        let plan = try FirmwareBootAdmission.plan(
            state: state,
            current: bytes(0xBB),
            candidate: bytes(0xCC),
            activeEnabled: [],
            candidateEnabled: [],
            now: now,
        )
        #expect(plan.target == .a)
        #expect(plan.state.a.state == .candidate)
    }

    @Test
    func `state round-trips through a property list`() throws {
        let state = try committedState()
        let encoded = try FirmwareBootAdmission.encode(state: state)
        #expect(try FirmwareBootAdmission.decodeState(encoded) == state)
    }

    @Test
    func `slot file names are stable`() {
        #expect(FirmwareBootAdmission.slotFileName(.a) == "a.img4")
        #expect(FirmwareBootAdmission.slotFileName(.b) == "b.img4")
        #expect(FirmwareBootAdmission.stateFileName == "BootState.plist")
        #expect(FirmwareBootAdmission.receiptFileName == "BootReceipt.plist")
    }
}

@Suite("Trace536 cave")
struct Trace536CaveTests {
    @Test
    func `restores x30 before retab`() throws {
        let cave = KernelCustomFirmwarePatcher.buildTrace536Cave(
            caveVA: 0x1_0000_0000,
            origVA: 0x1_0000_2000,
            logVA: 0x1_0000_3000,
        )
        let bytes = [UInt8](cave)
        var words: [UInt32] = []
        var index = 0
        while index + 4 <= bytes.count {
            words.append(
                UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24,
            )
            index += 4
        }
        let retab = try #require(words.lastIndex(of: 0xD65F_0FFF))
        #expect(words[retab - 2] == 0xA8C1_7BF5)  // ldp x21, x30, [sp], #0x10
        #expect(words[retab - 1] == 0xA8C1_53F3)  // ldp x19, x20, [sp], #0x10
        #expect(words.contains(0xB940_0689))  // ldr w9, [x20, #8]
        #expect(words.contains(0xB940_0E8B))  // ldr w11, [x20, #0x18]
        #expect(!words.contains(0xF940_0689))  // never an 8-byte read past a 16-byte argument block
        #expect(!words.contains(0xF940_0E8B))
    }
}
