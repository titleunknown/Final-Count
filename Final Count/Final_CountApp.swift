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
            FinalCountCommands()
        }
        .defaultSize(width: 1000, height: 700)
    }
}

// MARK: - Menu Commands

/// What the menu bar can do to the frontmost window, published by ContentView.
struct WindowActions {
    var addFolder: () -> Void
    var refresh: () -> Void
    var exportReport: () -> Void
    var canRefresh: Bool
    var canExport: Bool
    var showOnlyDifferences: Binding<Bool>
    var showFileTypeCounts: Binding<Bool>
    var includeHiddenFiles: Binding<Bool>
}

private struct WindowActionsKey: FocusedValueKey {
    typealias Value = WindowActions
}

extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

struct FinalCountCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { actions?.addFolder() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Report…") { actions?.exportReport() }
                .keyboardShortcut("e")
                .disabled(!(actions?.canExport ?? false))
        }
        CommandGroup(before: .toolbar) {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
                .disabled(!(actions?.canRefresh ?? false))
            Divider()
            Toggle("Show Only Differences", isOn: actions?.showOnlyDifferences ?? .constant(false))
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Toggle("Show File Type Counts", isOn: actions?.showFileTypeCounts ?? .constant(false))
                .disabled(actions == nil)
            Toggle("Include Hidden Files", isOn: actions?.includeHiddenFiles ?? .constant(false))
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
        }
    }
}
