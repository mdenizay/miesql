import SwiftUI
import MieSQLCore

/// The detail side: a tab strip over whichever tab is selected.
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !app.tabs.isEmpty {
                TabStrip()
                Divider()
            }

            if let tab = app.selectedTab {
                switch tab {
                case .query(let model):
                    QueryTabView(model: model)
                        .id(model.id)
                case .table(let model):
                    TableTabView(model: model)
                        .id(model.id)
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(app.t("workspace.empty.title"))
                .font(.title3.weight(.medium))
            Text(app.t("workspace.empty.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct TabStrip: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == app.selectedTabID)
                        .onTapGesture { app.selectedTabID = tab.id }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabChip: View {
    @EnvironmentObject private var app: AppModel
    let tab: WorkspaceTab
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            Button {
                app.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(app.t("general.close")) { app.closeTab(id: tab.id) }
        }
    }
}
