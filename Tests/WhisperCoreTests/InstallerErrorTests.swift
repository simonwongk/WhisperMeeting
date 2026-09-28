import Foundation
import Testing
@testable import WhisperCore

// F567 — an installer's failure is reported as an install failure, with the script's own last line
// as the reason, and "the previous version was kept" only when one was.

@Test("The reason is the installer's last line that says anything (F567)")
func installerReasonIsTheLastMeaningfulLine() {
    let log = """
    Collecting mlx-audio==0.3.1
    Fetching 4 files:  25%|██▌       | 1/4\rFetching 4 files: 100%|██████████| 4/4

    Could not download the speaker-analysis files. Check your connection and try again.


    """
    #expect(InstallerOutput.lastLine(of: log)
        == "Could not download the speaker-analysis files. Check your connection and try again.")

    // A progress bar redraws one physical line with \r: what a terminal shows is the last frame.
    #expect(InstallerOutput.lastLine(of: "Downloading  10%\rDownloading  55%\rDownloading 100%\n") == "Downloading 100%")
    // Colour codes are not text.
    #expect(InstallerOutput.lastLine(of: "\u{1B}[31mError:\u{1B}[0m python@3.11 is not installed\n")
        == "Error: python@3.11 is not installed")
    #expect(InstallerOutput.lastLine(of: "\n \n\t\n") == nil)
    #expect(InstallerOutput.failureReason(output: "", exitStatus: 7)
        == "The installer stopped with status 7 and printed no reason.")

    let long = String(repeating: "x", count: InstallerOutput.maximumReasonLength + 50)
    let capped = InstallerOutput.lastLine(of: long)
    #expect(capped?.count == InstallerOutput.maximumReasonLength + 1)
    #expect(capped?.hasSuffix("…") == true)
}

@Test("An install failure names the runtime and the script's reason, not a transcription (F567)")
func installerErrorNamesTheComponentAndReason() {
    let error = InstallerError.scriptFailed(
        .diarization,
        reason: "Could not download the speaker-analysis files. Check your connection and try again.",
        previousKept: false
    )
    #expect(error.localizedDescription
        == "Speaker analysis could not be installed. Could not download the speaker-analysis files. Check your connection and try again.")
    #expect(!error.localizedDescription.contains("transcript"))
    #expect(error.statusMessage
        == "Installation failed. Could not download the speaker-analysis files. Check your connection and try again.")
}

@Test("'The previous version was kept' is said only when there was one (F567)")
func previousVersionIsClaimedOnlyWhenKept() {
    let firstInstall = InstallerError.scriptFailed(.qwen, reason: "No network", previousKept: false)
    #expect(!firstInstall.localizedDescription.contains("previous"))
    #expect(firstInstall.localizedDescription == "Qwen3-ASR could not be installed. No network.")

    let repair = firstInstall.keepingPrevious(true)
    #expect(repair.statusMessage == "Installation failed. No network. The previous version was kept.")
    #expect(repair.keepingPrevious(false) == firstInstall)

    // Only a script failure can have kept anything; the other cases are unchanged by it.
    #expect(InstallerError.notReady(.whisper).keepingPrevious(true) == .notReady(.whisper))
    #expect(!InstallerError.notReady(.whisper).localizedDescription.contains("previous"))
}
