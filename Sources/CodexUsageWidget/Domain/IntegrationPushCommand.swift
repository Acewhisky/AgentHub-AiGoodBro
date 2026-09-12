import AppKit
import Foundation

enum IntegrationPushCommand {
    @MainActor static func sendAuthorizedPublicResetUpdate() -> Never {
        Task { @MainActor in
            let result = await PublicResetAnnouncementMonitor().sendAuthorizedLatest()
            exit(result)
        }
        // Keep main-queue Keychain completions running without starting the app.
        dispatchMain()
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        var exitCode: Int32 = 2
        var identifier = ""
        NextLocalNotificationService.shared.requestAlertAuthorization(userInitiated: true) { result in
            switch result {
            case .failure(let error):
                FileHandle.standardError.write(Data("integration-push blocked: \(String(describing: error))\n".utf8))
                exitCode = 3
            case .success:
                NextLocalNotificationService.shared.submitAuthorizedIntegrationPing { submit in
                    switch submit {
                    case .success(let receipt):
                        identifier = receipt.identifier
                        print("integration-push submitted")
                        exitCode = 0
                    case .failure(let error):
                        FileHandle.standardError.write(Data("integration-push failed: \(String(describing: error))\n".utf8))
                        exitCode = 4
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while exitCode == 2, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if exitCode == 2 {
            FileHandle.standardError.write(Data("integration-push timed out waiting for Notification Center\n".utf8))
            return 5
        }
        if exitCode == 0 {
            print("integration-push-id \(identifier)")
        }
        return exitCode
    }
}
