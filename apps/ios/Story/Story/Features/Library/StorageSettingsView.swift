import SwiftUI
import SwiftData

// R5 — Storage management (account-scoped). Opened as a sheet from the Moments Library. Shows local vs cloud
// storage + reclaimable space, a manual "Free Up Space" action, the "Optimize iPhone Storage" preference
// (default OFF, automatic policy gated until R5/R6 acceptance), a global "Keep Originals on iPhone" opt-out,
// honest offline messaging, and a DEBUG-only Protected eviction mode for acceptance. DISTINCT from Auto Backup.
struct StorageSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth

    /// Host supplies the account's Moments (already visibility-scoped) so the summary + eviction act on them.
    var moments: () -> [MomentModel]

    @State private var summary = StorageSummary()
    @State private var autoOptimize = false
    @State private var lastFreed: Int? = nil
    #if DEBUG
    @State private var protectedMode = true   // acceptance default: protect, don't delete
    #endif

    private var account: String? { auth.storyUserId }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Local originals on iPhone", bytes: summary.localOriginalBytes)
                    row("Backed up to your account", bytes: summary.cloudBackedBytes)
                    row("Reclaimable now", bytes: summary.reclaimableBytes)
                    LabeledContent("Cloud-only Moments", value: "\(summary.evictedCount)")
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Reclaimable space is the size of originals that are safely backed up and not in use. Freeing them keeps a preview on this iPhone and re-downloads the full video when you need it.")
                }

                Section {
                    Button {
                        guard let owner = account else { return }
                        var opt = StorageOptimizer(context: context, activeOwner: owner)
                        #if DEBUG
                        opt.protectedMode = protectedMode
                        #endif
                        let ms = moments()
                        Task {
                            lastFreed = await opt.freeUpSpace(moments: ms)
                            refresh()
                        }
                    } label: {
                        Label("Free Up Space", systemImage: "internaldrive")
                    }
                    .disabled(account == nil || summary.reclaimableBytes == 0)
                    if let f = lastFreed {
                        Text(f > 0 ? "Freed \(ByteCountFormatter.string(fromByteCount: Int64(f), countStyle: .file))."
                                   : "Nothing to free (or protected in this build).")
                            .font(.footnote).foregroundStyle(StoryTheme.cream.opacity(0.6))
                    }
                } footer: {
                    Text("Only videos confirmed backed up to your account are freed. Your cloud copy is never deleted, and ownership never changes.")
                }

                Section {
                    Toggle("Optimize iPhone Storage", isOn: Binding(
                        get: { autoOptimize }, set: { setAutoOptimize($0) }))
                    .tint(StoryTheme.gold)
                } footer: {
                    Text("When on, backed-up originals may be automatically freed to save space and re-downloaded on demand. This is OFF by default and separate from Auto Backup. (Automatic optimization stays disabled until testing is complete.)")
                }

                #if DEBUG
                Section {
                    Toggle("Protected eviction (move, don't delete)", isOn: $protectedMode)
                        .tint(StoryTheme.gold)
                } header: {
                    Text("Developer (acceptance)")
                } footer: {
                    Text("DEBUG only. Moves the original to a protected recovery location R6 cannot read, so a failed restore is recoverable. Protected bytes are not counted as freed.")
                }
                #endif
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: refresh)
        }
    }

    @ViewBuilder private func row(_ label: String, bytes: Int) -> some View {
        LabeledContent(label, value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
    }

    private func refresh() {
        guard let owner = account else { summary = StorageSummary(); return }
        autoOptimize = OptimizationStore(context: context).autoOptimizeEnabled(for: owner)
        summary = StorageOptimizer(context: context, activeOwner: owner).summary(moments: moments())
    }

    private func setAutoOptimize(_ on: Bool) {
        guard let owner = account else { return }
        OptimizationStore(context: context).setAutoOptimize(on, for: owner)
        autoOptimize = on
    }
}
