import ArgumentParser
import Darwin
import Foundation
import VPhoneCoreKit

/// Restore the kernel slot that booted before a pending candidate.
///
/// `cfw update-kernel` leaves the previous Preboot kernelcache in the other
/// slot. If the candidate panics, this writes that recorded slot back into
/// Preboot and marks the candidate bad. It runs no patch pipeline, so it works
/// even when the candidate's patch set is the thing that panicked.
struct VPhoneCustomFirmwareBootRollbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot-rollback",
        abstract: "Restore the previous kernel slot after a failed boot (root, VM must be off)",
        discussion: """
            The pending candidate is never committed. This command reads the active
            slot recorded by `cfw update-kernel`, verifies its SHA-256, writes it
            back into Preboot, and records a `panicked` receipt with the candidate
            marked bad. The machine must be stopped.
            """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .long,
        help: "Evidence recorded in BootReceipt.plist",
    )
    var evidence = "operator rollback after a failed boot"

    @Option(
        name: .customLong("work-parent"),
        help: "Root-owned private CFW temporary directory",
    )
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        setenv("VPHONE_BOOT_ROLLBACK_EVIDENCE", evidence, 1)
        let code = try VPhoneCustomFirmwareInstaller.elevate(
            bundle: bundle.url,
            resources: VPhoneResources.resolve(),
            mode: .kernelRollback,
            workParent: workParent,
        )
        throw ExitCode(code)
    }
}
