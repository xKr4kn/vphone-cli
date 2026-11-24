import Foundation

/// Pure completion rules for a bundle install.
///
/// A policy-only failure has no `error` text; treating only `error != nil` as
/// terminal left `isInstalling` true forever. The app keeps this logic free of
/// app state so the exact failed step can be tested without the UI.
nonisolated struct VPhoneLaunchpadInstallProgressRules {
    let hasError: Bool
    let hasFailedStep: Bool
    let isFinished: Bool
    let installPassed: Bool

    var overallFailed: Bool {
        hasError || hasFailedStep
    }

    var canSkip: Bool {
        overallFailed && installPassed && !isFinished
    }

    var isInstalling: Bool {
        !overallFailed && !isFinished
    }
}
