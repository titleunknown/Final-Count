//
//  Final_CountApp.swift
//  Final Count
//

import SwiftUI

@main
struct Final_CountApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .defaultSize(width: 1100, height: 750)
    }
}
