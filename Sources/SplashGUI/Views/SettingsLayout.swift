import SwiftUI
import AppKit

// One clipboard writer for every "copy the endpoint/config" control.
func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// macOS's grouped FormStyle centers its rows in a fixed ~704pt column, leaving large dead
// margins on a wide window. These keep the grouped-form look (header + rounded card) while
// letting the cards fill the detail column.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        // NSHostingView never resigns the field editor when a click lands on a non-control
        // area, so a focused field's ring stayed lit after clicking elsewhere. A tap that no
        // control consumed (fields, buttons and toggles eat their own clicks) ends editing —
        // matching AppKit: empty space deselects, clicking another control behaves natively.
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct SettingsSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}