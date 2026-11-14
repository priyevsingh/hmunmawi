import SwiftUI

/// One sheet at a time (Apple's HIG for sheets: "If something people do within a sheet results in another sheet
/// appearing, close the first sheet before displaying the new one. If necessary, you can display the first sheet again
/// after people dismiss the second one."). A host presents a root sheet; anything inside it that needs another sheet
/// calls `openSheet` instead of stacking one on top. The first closes, the second opens, and closing the second brings
/// the first back, freshly built (so lists in it show what the second changed).
struct SheetSlot: Identifiable {
    let id = UUID()
    let make: () -> AnyView
}

/// `openSheet { AnyView(...) }`: opens another sheet in place of this one.
struct OpenSheetAction: @unchecked Sendable {
    let run: (@escaping () -> AnyView) -> Void
    func callAsFunction(_ make: @escaping () -> AnyView) { run(make) }
}

private struct OpenSheetKey: EnvironmentKey {
    static let defaultValue: OpenSheetAction? = nil
}
extension EnvironmentValues {
    /// Set by `sheetFlow`; nil outside one.
    var openSheet: OpenSheetAction? {
        get { self[OpenSheetKey.self] }
        set { self[OpenSheetKey.self] = newValue }
    }
}

extension View {
    func sheetFlow(isPresented: Binding<Bool>, root: @escaping () -> AnyView) -> some View {
        modifier(SheetFlowHost(isPresented: isPresented, root: root))
    }
}

private struct SheetFlowHost: ViewModifier {
    @Binding var isPresented: Bool
    let root: () -> AnyView
    @State private var stack: [SheetSlot] = []

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, on in
                if on, stack.isEmpty { stack = [SheetSlot(make: root)] }
                if !on { stack = [] }
            }
            .sheet(item: Binding(
                get: { stack.last },
                set: { new in
                    guard new == nil else { return }
                    // Dismissed: the sheet it came from (if any) comes back; with none left the flow is over.
                    if !stack.isEmpty { stack.removeLast() }
                    if stack.isEmpty { isPresented = false }
                })
            ) { slot in
                slot.make().environment(\.openSheet, OpenSheetAction { make in stack.append(SheetSlot(make: make)) })
            }
    }
}
