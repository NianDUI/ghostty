import Foundation
import Testing
@testable import Ghostty

struct SSHImagePasteSettingsTests {
    @Test func storeUsesDefaultsWhenNothingWasSaved() {
        let suite = "SSHImagePasteSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SSHImagePasteSettingsStore(defaults: defaults, key: "settings")
        #expect(store.load() == SSHImagePasteSettings())
    }

    @Test func storeRoundTripsSettings() {
        let suite = "SSHImagePasteSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SSHImagePasteSettingsStore(defaults: defaults, key: "settings")
        let expected = SSHImagePasteSettings(
            enabled: true,
            maxImageBytes: 50 * 1024 * 1024,
            remoteBaseDirectory: "/var/tmp")
        store.save(expected)

        #expect(store.load() == expected)
    }

    @Test func remoteDirectoryMustBeAnAbsolutePath() {
        #expect(SSHImagePasteSettingsValidation.message(remoteBaseDirectory: "tmp") != nil)
        #expect(SSHImagePasteSettingsValidation.message(remoteBaseDirectory: "/tmp") == nil)
    }

    @Test func remotePathUsesSurfaceAndImageIdentifiers() {
        let surfaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let imageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        #expect(SSHImagePastePath.remotePath(
            baseDirectory: "/tmp/",
            surfaceID: surfaceID,
            imageID: imageID
        ) == "/tmp/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
    }

    @Test func extractsUploadArgumentsFromRunningSSH() {
        let command = "ssh -t -i /Users/test/.ssh/id_ed25519 dev@192.168.64.5 cd /work"
        let arguments = SSHImagePasteRunningSSH.uploadArguments(commandLine: command)

        #expect(arguments == [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-i", "/Users/test/.ssh/id_ed25519",
            "dev@192.168.64.5",
        ])
    }

    @Test func rejectsCommandsOtherThanSSH() {
        #expect(SSHImagePasteRunningSSH.uploadArguments(commandLine: "bash -l") == nil)
    }

    @Test func findsSSHBelowTrzszProcessWrappers() {
        let processes = """
          100     1 /usr/bin/login -flp test /bin/zsh
          101   100 /opt/homebrew/bin/trzsz -z -d /bin/zsh -l
          102   101 /bin/zsh -l
          103   102 ssh -t -i /Users/test/.ssh/id_ed25519 dev@192.168.64.5 cd /work
        """

        let arguments = SSHImagePasteRunningSSH.uploadArguments(
            processList: processes,
            rootPID: 100)
        #expect(arguments?.suffix(3) == [
            "-i", "/Users/test/.ssh/id_ed25519", "dev@192.168.64.5",
        ])
    }
}
