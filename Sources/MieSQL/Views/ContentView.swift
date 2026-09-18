import SwiftUI
import MieSQLCore

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            WorkspaceView()
        }
        .sheet(item: $app.editingProfile) { profile in
            ConnectionEditorView(profile: profile, startInURLMode: app.editorStartsInURLMode)
                .environmentObject(app)
        }
        .sheet(item: $app.passwordRequest) { request in
            PasswordPromptView(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.dumpRequest) { request in
            DumpSheet(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.scriptRequest) { request in
            RunScriptSheet(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.importRequest) { request in
            CSVImportSheet(request: request)
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingHistory) {
            HistoryView()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingPalette) {
            CommandPaletteView()
                .environmentObject(app)
        }
        .alert(item: $app.alert) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text(app.t("general.ok")))
            )
        }
        .confirmationDialog(
            app.confirmation?.title ?? "",
            isPresented: Binding(
                get: { app.confirmation != nil },
                set: { if !$0 { app.confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: app.confirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                confirmation.action()
                app.confirmation = nil
            }
            Button(app.t("general.cancel"), role: .cancel) {
                app.confirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
