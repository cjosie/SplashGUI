import SwiftUI
import UniformTypeIdentifiers

struct RunTab: View {
    @EnvironmentObject var model: AppModel
    @State private var showAddLocal = false

    var body: some View {
        // The server controls (Start/Stop, port, chips, context slot) live in the custom
        // title bar — see ServerToolbarControls in StatusWidgets.swift + RootView.titleBar.
        SettingsPage {
            SettingsSection("Model & Server") {
                HStack(alignment: .top, spacing: 28) {
                    modelColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    serverColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection("Engine") {
                Toggle("Start server on app launch", isOn: $model.config.startOnLaunch)
                    .help("Launch SplashGUI and it serves the saved model on the saved port, no click needed. A server already on the port is adopted instead of double-launched; engine updates (per the source setting below) install first. Quitting stops the server.")
                HStack(spacing: 6) {
                    Text("Engine source")
                        .fixedSize(horizontal: true, vertical: false)
                    Picker("Engine source", selection: $model.config.engineMode) {
                        Text("This build's pin (\(EngineInstaller.defaultPin.version))").tag(EngineMode.pinned)
                        Text(model.homebrewEngineVersion.map { "Homebrew install (\($0))" }
                             ?? "Homebrew install (not found)").tag(EngineMode.homebrew)
                        Text("Always latest release").tag(EngineMode.latest)
                        Text("Custom pin").tag(EngineMode.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .help("Pinned: always run the engine version this SplashGUI was released and tested with; bumping it takes a new app build. A Homebrew-installed engine at or above that version is used instead of downloading a copy. Homebrew: use the engine `brew install splash` put on this Mac, whatever version it is — `brew upgrade splash` updates it and no copy is downloaded. Latest: before every start, check GitHub's newest Splash release and install it (checksum verified against the release's own .sha256); if GitHub can't be reached the installed engine stays. Homebrew is not consulted here. Custom: install the exact build named by the three fields below.")
                switch model.config.engineMode {
                case .pinned:
                    Toggle("Check for engine update on start", isOn: $model.config.checkEngineUpdate)
                        .help("On: each start installs the engine this SplashGUI build pins if a different one is installed. Off: only download if no engine is installed yet.")
                case .homebrew:
                    Text("Uses the engine Homebrew installed at /opt/homebrew/opt/splash, whatever version it is; `brew upgrade splash` updates it. No download. If Homebrew's copy is missing, the pinned engine is used.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .latest:
                    Text("Checks GitHub on every start; a newer release downloads before the server launches. Unreachable GitHub keeps the installed engine. Homebrew installs are not consulted.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .custom:
                    // No disclosure wrapper: the picker already hides these unless Custom is
                    // picked, so a second fold on top is just one more click.
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledField("Engine version", $model.config.engineVersionOverride, width: 150)
                        LabeledField("Engine URL", $model.config.engineURLOverride, width: 360)
                        LabeledField("SHA-256", $model.config.engineSHA256Override, width: 360)
                        Text("All three are required; they override the published pin entirely.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Installed engine")
                    Spacer()
                    Text(installedEngineText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            logPane
        }
        .sheet(isPresented: $showAddLocal) {
            AddLocalModelSheet().environmentObject(model)
        }
    }

    // The two columns are separate computed properties: inline they push the GridRow's
    // result-builder tree past the type-checker's complexity limit.

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Model")
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Model", selection: model.modelPickerSelection) {
                    Section("Splash suggested") {
                        ForEach(CatalogModel.catalog.filter { $0.id != "custom" }) { m in
                            modelRow(label: m.label, id: m.id)
                        }
                    }
                    if !model.config.savedModels.isEmpty {
                        Section("Saved") {
                            ForEach(model.config.savedModels) { s in
                                modelRow(label: s.label, id: s.id)
                            }
                        }
                    }
                    Text("Custom…").tag("custom")
                }
                .labelsHidden()
            }
            .help("Hub ID, owner/repo[:variant], shown so you know exactly whose upload you're pulling. The DFlash2 draft model pairs automatically. First start downloads weights and prepares them; later starts map from disk. Each model keeps its own sampling and context settings, saved under its full ID including the :variant; switching models swaps them in, and a model you have not tuned starts on its card's sampling.")
            if model.catalogEntry == nil, model.savedEntry == nil {
                customRows
            }
            if let saved = model.savedEntry {
                savedRows(saved)
            }
            if let entry = model.catalogEntry {
                catalogStatusRow(entry)
            } else if let local = model.localEntry {
                localStatusRow(local)
            } else if let saved = model.savedEntry, !saved.isLocal {
                hubSavedStatusRow(saved)
            }
            Toggle(isOn: $model.config.run.auto) {
                HStack(spacing: 6) {
                    Text("Auto")
                    if model.catalogEntry == nil && model.config.run.auto {
                        Text("custom models fill auto settings once Splash launches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .help("Size context, memory and KV precision from this Mac's GPU memory ceiling and the selected model's weights, and let the engine size the SSD cache. The greyed fields show what Auto picked; turn it off to use your own values.")
            LabeledField("Max context", autoAwareText($model.config.run.maxContext, model.autoContextText), width: 120)
                .disabled(model.config.run.auto)
                .help("Context limit: a number with optional K, e.g. 100K or 131072. Lower frees KV memory. With Auto on, the app sizes it from this Mac's GPU memory and the model's weights, up to 262144 tokens.")
            LabeledField("Max memory", autoAwareText($model.config.run.maxMemory, model.autoMemoryText), width: 120)
                .disabled(model.config.run.auto)
                .help("Cap on Metal allocations, e.g. 28G. Lower it to leave room for other GPU work. With Auto on, the app uses this Mac's GPU memory ceiling: \(MachineInfo.gb(MachineInfo.metalMaxWorkingSet)) here, of \(MachineInfo.gb(MachineInfo.physicalRAM)) physical RAM (recommendedMaxWorkingSetSize).")
            LabeledField("SSD cache", autoAwareText($model.config.run.maxCacheDisk, model.autoCacheText), width: 120)
                .disabled(model.config.run.auto)
                .help("SSD cache for KV pages and GDN states, e.g. 16G; 0 turns it off. With Auto on, the engine sizes it: a quarter of the volume's free space, up to 32G. A 64K context costs 2.0 GiB of pages here plus a 152 MiB state. The cache does not raise the context limit. Free disk on this volume: \(MachineInfo.gb(MachineInfo.freeDisk)).")
            Toggle("Keep SSD cache across restarts", isOn: $model.config.run.persistentCache)
                .help("Write the SSD tier to ~/Library/Caches/Splash/prefix-cache instead of a temporary directory, so a project you come back to restores its prefix rather than prefilling it again. Needs an SSD cache above 0.")
            HStack(spacing: 6) {
                Text("KV cache")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("KV cache", selection: kvSelection) {
                    Text("BF16").tag("bf16")
                    Text("INT8").tag("int8")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.config.run.auto)
                .help("KV cache precision. BF16 is fastest at long contexts and exact; INT8 halves KV memory for RAM-constrained machines, but slows decode at depth and can cost accuracy (4-bit KV exists in Splash but is not offered here). With Auto on, the app picks BF16 and only drops to INT8 when BF16 would leave under a 32K window. Restart to apply.")
            }
            LabeledField("Thinking budget", $model.config.run.thinkingTokenBudget, width: 150)
                .help("Thinking tokens for requests that set no budget of their own, e.g. 16384; when it runs out the thinking closes and the answer follows. Blank means no cap (the engine default). Restart to apply.")
            if model.memoryKnobs.ple {
                LabeledField("PLE memory", $model.config.run.pleMemory, width: 120)
                    .help("RAM held for the PLE n-gram table of a Qwen3.8-Flash-Next GGUF, e.g. 2G; the rest streams from the SSD. Blank leaves it to the engine, which streams when RAM cannot hold the whole table. Restart to apply.")
            }
            if model.memoryKnobs.expert {
                LabeledField("Expert memory", $model.config.run.expertMemory, width: 120)
                    .help("RAM slots for the routed experts of a MoE model, e.g. 16G; the others read from the SSD when a token routes them. Blank leaves it to the engine, which loads every expert that fits. Restart to apply.")
            }
            if model.memoryKnobs.sparseKv {
                LabeledField("Sparse-KV memory", $model.config.run.sparseKvMemory, width: 120)
                    .help("RAM cache of the KV blocks this block-sparse model reads from the SSD, e.g. 1200M; never below the engine's floor. Blank keeps the floor. Restart to apply.")
            }
            Toggle("Verify all draft rows", isOn: $model.config.run.verifyRowsAll)
                .help("Decode-verify every row of each draft block instead of a learned subset. A MoE model's greedy and seeded outputs then repeat run to run, like a dense model's; the full check costs some decode speed. Off leaves it to the engine. Restart to apply.")
        }
    }

    private func modelRow(label: String, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(id)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(id)
    }

    // The Custom… slot: the typed ID, the field, and the two ways to keep a model.
    private var customRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.config.run.modelID.isEmpty
                     ? "no model ID set; pick Custom… and type owner/repo[:variant]"
                     : model.config.run.modelID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            TextField("owner/repo[:variant]", text: model.customIDBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack(spacing: 6) {
                if SavedModel.validID(model.config.run.modelID) {
                    Button("Save to list") { saveCustomToList() }
                        .help("Keeps this ID in the picker's Saved section, so switching away and back restores it with its own settings — no retyping.")
                }
                Button("Add local model…") { showAddLocal = true }
                    .help("Serve a GGUF file or model directory already on this Mac — no Hugging Face download.")
                Spacer()
            }
        }
    }

    private func saveCustomToList() {
        let id = model.config.run.modelID
        let repo = id.split(separator: ":").first.map(String.init) ?? id
        let label = repo.split(separator: "/").last.map(String.init) ?? repo
        model.saveModel(id: id, label: label)
    }

    // A selected saved entry: rename inline, or remove from the list (its settings stay
    // saved under the model ID, exactly like a catalog row you stop showing).
    private func savedRows(_ saved: SavedModel) -> some View {
        HStack(spacing: 6) {
            TextField("Name", text: savedLabelBinding(saved.id))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button("Remove") { model.removeSavedModel(id: saved.id) }
                .help("Removes it from the Saved list. Its sampling and serve settings stay saved under the model ID; re-adding it restores them.")
            Spacer()
        }
    }

    private func savedLabelBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { model.config.savedModels.first { $0.id == id }?.label ?? "" },
            set: { model.renameSavedModel(id: id, to: $0) }
        )
    }

    private func catalogStatusRow(_ entry: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: entry.onDisk ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(entry.onDisk ? Color.green : Color.orange)
                // One Text, not two: separate Texts wrap independently, so on a narrow window
                // the note dropped to its own line instead of flowing after the status.
                Text("\(entry.onDisk ? "installed, maps from disk" : "not installed, first start pulls it from Hugging Face") · \(entry.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .help((entry.downloadURL.map { "pulls, pinned to commit \($0). " } ?? "")
                  + "serve --revision pins the download to this exact commit, so a later re-upload under the same file name cannot change what loads. The catalog also carries its sha256; the app checks it against the digest Splash records before starting.")
            if !entry.fitsThisMac {
                Label("too large for this Mac's memory, expected to fail",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // A saved Hub entry reads its installed state off the same disk layout as a catalog row;
    // it tracks the repository's default branch (no revision pin in v1).
    private func hubSavedStatusRow(_ saved: SavedModel) -> some View {
        let onDisk = MachineInfo.weightsDir(for: saved.id) != nil
        return HStack(spacing: 6) {
            Image(systemName: onDisk ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(onDisk ? Color.green : Color.orange)
            Text(onDisk
                 ? "installed, maps from disk"
                 : "not installed, first start pulls it from Hugging Face")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .help("Saved Hub ID, pulled from the repository's default branch. Its full ID and settings stay under \(saved.id).")
    }

    private func localStatusRow(_ local: SavedModel) -> some View {
        let status = Self.localStatus(local)
        return HStack(spacing: 6) {
            Image(systemName: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(status.ok ? Color.green : Color.red)
            Text(status.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .help("Served from disk with serve --model-dir; the API reports \(local.id). No Hugging Face download. A GGUF serves text only unless a vision projector is attached; the DFlash2 draft pairs from the Hugging Face cache when one is recorded for the family.")
    }

    // One line about a local entry's files: "local · <path> · <size>", or what is wrong.
    static func localStatus(_ local: SavedModel) -> (ok: Bool, text: String) {
        guard FileManager.default.fileExists(atPath: local.path) else {
            return (false, "local file not found: \(local.path)")
        }
        guard MachineInfo.localLooksLikeModel(path: local.path) else {
            return (false, "not a GGUF file or model directory: \(local.path)")
        }
        var text = "local · \(local.path) · \(MachineInfo.gb(MachineInfo.localWeightsSize(path: local.path)))"
        if !local.mmproj.isEmpty { text += " · + projector" }
        return (true, text)
    }

    private var serverColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Served name leads the server column: it names the endpoint, next to the port
            // field in the title bar above.
            LabeledField("Served name", $model.config.run.servedModelName, width: 120)
                .help("An additional model name the API answers to, e.g. qwen27, so client configs stay short and stable across quants. The Provider tab writes it in place of the full Hub ID; /status keeps reporting the loaded model ID. Every model keeps its own name. Restart to apply.")
            Toggle("Report served name in responses", isOn: $model.config.run.announceServedName)
                .disabled(model.config.run.servedModelName.isEmpty)
                .help("Responses report the served name and /v1/models lists it first; off (the engine default) they report the loaded model ID. Needs a served name. Restart to apply.")
            LabeledField("Idle release", $model.config.run.idleRelease, width: 120)
                .help("How long the engine keeps its memory wired without a request: a duration such as 30m or 2h, or off. The engine's own default is 10m, after which the next request pays a weight restore and a slower first prefill. off keeps the weights resident until POST /v1/memory/release.")
            SliderNumberField(
                label: "Decode share",
                value: $model.config.run.decodeShare,
                range: 0...1, step: 0.05, digits: 2
            )
            .help("When a long prompt prefills while other requests decode, each prefill slice owes this fraction of its own duration to the decoding lanes. 0.5 default; higher keeps in-flight outputs fast at the cost of the new prompt's TTFT; 0 alternates one command each. Only matters under concurrency.")
            HStack(spacing: 6) {
                Text("Default reasoning effort")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Default reasoning effort", selection: model.reasoningEffortBinding) {
                    Text("model default").tag(String?.none)
                    ForEach(model.supportedEfforts, id: \.self) { e in
                        Text(e).tag(String?.some(e))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The effort Splash uses for requests that don't set one, such as the web chat on Default or OpenCode with no variant picked. Clients that ask for an effort get what they ask for, and Anthropic-style clients like Claude Code always say. Restart to apply.")
                Spacer()
            }
            Toggle("Language only (skip vision)", isOn: $model.config.run.languageOnly)
                .help("Serve text only: skips loading the vision projector, saving memory. Restart to apply.")
            HStack(spacing: 6) {
                Toggle("Built-in web chat page", isOn: $model.config.run.showWebUI)
                    .help("Serve Splash's built-in chat page at the server URL.")
                // The button only shows when the page is served (--no-webui means no URL to open).
                if model.config.run.showWebUI, model.phase == .ready {
                    Button("Open built-in chat") { openWebChat() }
                }
                Spacer()
            }
            Toggle("Serve on LAN", isOn: $model.config.run.lanAccess)
                .help("Let other machines on your network connect: the server binds every network interface instead of this Mac only. Restart to apply. The API has no key — anyone on the network can use the model and the chat page. macOS may ask you to allow incoming connections for the Splash engine. This Mac keeps connecting over 127.0.0.1 either way.")
            if model.config.run.lanAccess {
                HStack(spacing: 6) {
                    Text("Other machines connect to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("http://" + (MachineInfo.lanIPv4Address ?? "no leased address") + ":"
                         + String(model.config.run.port) + "/v1")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }
            }
            Toggle("Serve offline (skip Hub check)", isOn: $model.config.run.offline)
                .help("Start without contacting Hugging Face: the model loads straight from the local cache. Use it on a plane or when the Hub is unreachable; a model that has never been downloaded cannot start this way. Restart to apply.")
        }
    }

    private var installedEngineText: String {
        let version = model.engineVersion ?? "not installed"
        return EngineInstaller.currentIsExternal ? "\(version) · Homebrew" : version
    }

    private func openWebChat() {
        if let url = URL(string: "http://127.0.0.1:" + String(model.config.run.port)) {
            NSWorkspace.shared.open(url)
        }
    }

    // While Auto is on the field shows Auto's value and swallows edits (it is disabled — this
    // binding just keeps the typed value untouched underneath).
    private func autoAwareText(_ typed: Binding<String>, _ autoValue: String) -> Binding<String> {
        Binding(
            get: { model.config.run.auto ? autoValue : typed.wrappedValue },
            set: { if !model.config.run.auto { typed.wrappedValue = $0 } }
        )
    }

    // The KV picker follows the same rule: Auto's pick while Auto is on, the typed value below.
    private var kvSelection: Binding<String> {
        Binding(
            get: { model.config.run.auto ? model.autoKVFormat : model.config.run.kvFormat },
            set: { if !model.config.run.auto { model.config.run.kvFormat = $0 } }
        )
    }

    @ViewBuilder
    private var logPane: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logTail.isEmpty
                             ? "no log output yet"
                             : model.logTail.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.logTail.isEmpty ? .tertiary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("logEnd")
                    }
                    .frame(height: 170)
                    .onChange(of: model.logTail.count) {
                        proxy.scrollTo("logEnd", anchor: .bottom)
                    }
                }
                if !model.logTail.isEmpty {
                    Button {
                        let text = model.logTail.joined(separator: "\n")
                        copyToClipboard(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the log to the clipboard")
                    .padding(6)
                }
            }
        }
        .background(.bar)
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat

    init(_ title: String, _ text: Binding<String>, width: CGFloat) {
        self.title = title
        self._text = text
        self.width = width
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// The Add-local-model form: pick the GGUF file or model directory already on disk, name it,
// and keep it in the Saved list. Paths are stored as plain strings — the app is not sandboxed.
struct AddLocalModelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var label = ""
    @State private var apiID = ""
    @State private var mmproj = ""
    // Typing in Name or API ID stops the auto-fill from the file name; re-picking a file
    // resets both.
    @State private var labelEdited = false
    @State private var apiEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add local model").font(.headline)
            HStack(spacing: 6) {
                Text("Model")
                    .fixedSize(horizontal: true, vertical: false)
                Text(path.isEmpty ? "no file or directory picked" : path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { chooseModel() }
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Projector")
                    .fixedSize(horizontal: true, vertical: false)
                Text(mmproj.isEmpty ? "none (a GGUF serves text only)" : mmproj)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(mmproj.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if mmproj.isEmpty {
                    Button("Attach…") { chooseProjector() }
                } else {
                    Button("Detach") { mmproj = "" }
                }
                Spacer()
            }
            .help("A GGUF vision projector file (mmproj-*.gguf) that lets a GGUF target serve images. MLX directories carry their vision tower in the checkpoint and need none.")
            LabeledField("Name", labelBinding, width: 300)
            LabeledField("API ID", apiBinding, width: 300)
                .help("The model name the API reports, like a Hub ID. It defaults to local/<file name>; clients address the model by it.")
            statusLine
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !path.isEmpty {
                let status = RunTab.localStatus(SavedModel(id: apiID, label: label, path: path, mmproj: mmproj))
                Text(status.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(status.ok ? Color.secondary : Color.red)
            }
            if !SavedModel.validID(apiID) {
                Text("API ID must be owner/repo[:variant], e.g. local/my-model:Q4_K_M")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !mmproj.isEmpty, model.config.run.languageOnly {
                Text("Language only is on, which refuses a projector — turn it off on the Run tab or detach it.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if canAdd, model.config.savedModels.contains(where: { $0.id == apiID }) {
                Text("An entry with this ID already exists; Add updates its path and name.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canAdd: Bool {
        !path.isEmpty && !label.trimmingCharacters(in: .whitespaces).isEmpty
            && SavedModel.validID(apiID)
            && MachineInfo.localLooksLikeModel(path: path)
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { label },
            set: { labelEdited = true; label = $0 }
        )
    }

    private var apiBinding: Binding<String> {
        Binding(
            get: { apiID },
            set: { apiEdited = true; apiID = $0 }
        )
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [.directory, gguf]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        if !labelEdited {
            label = Self.defaultLabel(forPath: path)
        }
        if !apiEdited {
            apiID = SavedModel.localID(forPath: path)
        }
    }

    private func chooseProjector() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        if panel.runModal() == .OK, let url = panel.url {
            mmproj = url.path
        }
    }

    // The file or directory name without its .gguf ending — what the user calls this model.
    static func defaultLabel(forPath path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(".gguf".count)) }
        return name
    }

    private func add() {
        guard model.saveModel(id: apiID, label: label, path: path, mmproj: mmproj) else { return }
        model.selectModelID(apiID)
        dismiss()
    }
}
