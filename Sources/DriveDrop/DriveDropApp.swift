import SwiftUI

@main
struct DriveDropApp: App {
    @StateObject private var store = MigrationStore()

    var body: some Scene {
        WindowGroup("DriveDrop") {
            MainWindowView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
