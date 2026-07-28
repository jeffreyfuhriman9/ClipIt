import SwiftUI

struct ClipTitleEditView: View {
    let clip: Clip
    let onSave: (Clip) -> Void
    let onDelete: (() -> Void)? // Passed down to handle clip destruction seamlessly

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var showDeleteAlert = false

    // Updated init to take the optional deletion closure matching your session architecture
    init(clip: Clip, onDelete: (() -> Void)? = nil, onSave: @escaping (Clip) -> Void) {
        self.clip = clip
        self.onDelete = onDelete
        self.onSave = onSave
        _title = State(initialValue: clip.customTitle ?? clip.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Clip Title", text: $title)
                        .textInputAutocapitalization(.words)
                        // 👇 The native overlay approach
                        .overlay(
                            HStack {
                                Spacer()
                                if !title.isEmpty {
                                    Button {
                                        title = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(Color(UIColor.tertiaryLabel))
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        )
                }

                Section {
                    Text("This will rename the clip without changing the video.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                // 🔥 NEW SECTION: Inline Form Row Deletion Mechanic
                if onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Clip")
                                    .fontWeight(.medium)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        var updatedClip = clip
                        updatedClip.customTitle = cleanedTitle.isEmpty ? nil : cleanedTitle
                        onSave(updatedClip)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            // Confirmation prompt guard before executing permanent data deletion
            .alert("Delete Clip?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    dismiss() // Close the edit sheet modal
                    onDelete?() // Fire parent deletion handling loop
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to permanently remove this highlight? This action cannot be undone.")
            }
        }
    }
}
