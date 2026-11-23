import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneCoreKit

/// Finish the A/B kernel transaction after the guest booted and answered.
///
/// `cfw update-kernel` writes the candidate to the inactive slot and Preboot,
/// then records a pending boot. This verb promotes the candidate only after
/// the owner has seen the guest boot; the previous kernel stays as standby.
struct VPhoneCustomFirmwareBootCommitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot-commit",
        abstract: "Commit the pending kernel slot after the VM booted successfully",
        discussion: """
            `cfw update-kernel` writes the candidate kernelcache into the inactive
            slot and Preboot, then records a pending boot. Start the VM; once
            vphoned answers, stop it and run this. It promotes the candidate and
            keeps the previous kernel as standby.
            """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .long,
        help: "Evidence that the guest booted, recorded in BootReceipt.plist",
    )
    var evidence = "operator confirmed the guest booted"

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let disk = bundle.url.appendingPathComponent("Disk.img").path
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", disk],
        )
        let holders = VPhoneLsof.parsePIDs(busy.stdout).filter { $0 != getpid() }
        guard holders.isEmpty else {
            throw ValidationError("Stop \(name) before committing its boot.")
        }

        let directory = try VPhoneConfinedDirectory(root: bundle.url.path)
        guard (try? directory.isRegularFile(FirmwareBootAdmission.stateFileName)) == true else {
            throw ValidationError(
                "\(name) has no boot state. Run `vphone-cli cfw update-kernel \(name)` first.",
            )
        }
        let state = try FirmwareBootAdmission.decodeState(
            try directory.readData(FirmwareBootAdmission.stateFileName),
        )
        let (next, receipt) = try FirmwareBootAdmission.commit(
            state: state, evidence: evidence, now: Date(),
        )
        try directory.writeFile(
            FirmwareBootAdmission.stateFileName,
            contents: try FirmwareBootAdmission.encode(state: next),
            mode: 0o777,
        )
        try directory.writeFile(
            FirmwareBootAdmission.receiptFileName,
            contents: try FirmwareBootAdmission.encodeReceipt(receipt),
            mode: 0o777,
        )
        print(
            "[+] Kernel slot \(next.active.rawValue.uppercased()) committed; the previous slot is standby",
        )
    }
}
