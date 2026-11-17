import SwiftUI

/// Keeps recoverable deletion unavailable while a share snapshot/save panel is
/// open. Each mounted sheet owns its lease, including when multiple windows exist.
struct MeetingDeletionShareSession: ViewModifier {
    let store: AppStore
    @State private var sessionID: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if sessionID == nil { sessionID = store.beginMeetingSharingSession() }
            }
            .onDisappear {
                if let sessionID { store.endMeetingSharingSession(sessionID) }
                sessionID = nil
            }
    }
}
