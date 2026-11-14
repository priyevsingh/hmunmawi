import HmunmawiCore
import SwiftUI

/// On Today with "All projects" picked and more than one project saved: one line per project with its own headline
/// numbers, and a tap switches to that project. A website's numbers come from its own sections (the one marked as the
/// headline, else the first by its order); an apps project shows its apps. Nothing is shown with a single project.
struct ProjectsStrip: View {
    let model: AppModel
    @Environment(DetailPresenter.self) private var detail: DetailPresenter?
    private let store = ProjectStore.shared

    private struct Row: Identifiable {
        let project: Project
        let subtitle: String
        let figures: [CustomSection.Figure]
        var id: String { project.id }
    }

    private func rows() -> [Row] {
        let sections = model.snapshots("section.snapshot")
        return store.projects.map { p in
            let mine = sections.filter { store.owner(of: $0.app)?.id == p.id }
            let flagged = mine.first { $0.payload[path: "headline"] == .bool(true) }
            let lead = flagged.flatMap(CustomSection.init)
                ?? mine.compactMap(CustomSection.init).filter { !$0.figures.isEmpty }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }.first
            let apps = model.snapshots("app.snapshot").compactMap(\.app).filter { store.owner(of: $0)?.id == p.id }.map(ComingSoon.shortName)
            let subtitle = !apps.isEmpty ? apps.joined(separator: ", ")
                : p.kind == .website ? "Website" : p.kind == .apps ? "Apps" : "Project"
            return Row(project: p, subtitle: subtitle, figures: Array((lead?.figures ?? []).prefix(4)))
        }
    }

    var body: some View {
        if store.selected == nil, store.projects.count > 1 {
            let all = rows()
            KitCard {
                CardHeader(symbol: "square.stack.3d.up.fill", title: "Your projects", tint: Brand.Category.web,
                           caption: "Tap one to see only its numbers")
                ForEach(Array(all.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    Button {
                        detail?.closeAll()
                        store.selectedID = row.project.id
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            IconBadge(symbol: row.project.symbol, tint: Brand.Category.web, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.project.name).font(.headline)
                                Text(row.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            ForEach(row.figures) { f in
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(CustomSection.format(f.value, f.format)).font(.title3.weight(.bold)).monospacedDigit()
                                    Text(f.label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(minWidth: 70, maxWidth: 150, alignment: .trailing)
                            }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show only \(row.project.name)")
                }
            }
        }
    }
}
