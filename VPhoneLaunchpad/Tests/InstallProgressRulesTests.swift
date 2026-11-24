import Foundation

@main
struct InstallProgressRulesTests {
    static func main() {
        // The exact persisted failure: install and preflight passed, policy
        // failed, and no error text was attached.
        let policyOnly = VPhoneLaunchpadInstallProgressRules(
            hasError: false,
            hasFailedStep: true,
            isFinished: false,
            installPassed: true,
        )
        precondition(policyOnly.overallFailed, "a failed step is terminal")
        precondition(!policyOnly.isInstalling, "a failed step is not still installing")
        precondition(policyOnly.canSkip, "a post-install failure can be skipped")

        let running = VPhoneLaunchpadInstallProgressRules(
            hasError: false,
            hasFailedStep: false,
            isFinished: false,
            installPassed: false,
        )
        precondition(!running.overallFailed, "still running is not failed")
        precondition(running.isInstalling, "still running is installing")
        precondition(!running.canSkip, "nothing can be skipped yet")

        let finished = VPhoneLaunchpadInstallProgressRules(
            hasError: false,
            hasFailedStep: false,
            isFinished: true,
            installPassed: true,
        )
        precondition(!finished.overallFailed, "a finished install is not failed")
        precondition(!finished.isInstalling, "a finished install is not installing")
        precondition(!finished.canSkip, "a finished install needs no skip")

        let failedBeforeInstall = VPhoneLaunchpadInstallProgressRules(
            hasError: true,
            hasFailedStep: true,
            isFinished: false,
            installPassed: false,
        )
        precondition(failedBeforeInstall.overallFailed, "an error is terminal")
        precondition(!failedBeforeInstall.isInstalling, "an error is not still installing")
        precondition(!failedBeforeInstall.canSkip, "nothing was installed to skip to")

        print("Install progress rule tests passed")
    }
}
