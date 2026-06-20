import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }

            TypingSettings()
                .tabItem { Label("Typing", systemImage: "keyboard") }

            CandidateSettings()
                .tabItem { Label("Suggestions", systemImage: "list.bullet.rectangle") }

            ExperimentalSettings()
                .tabItem { Label("Experimental", systemImage: "flask") }
        }
        .frame(width: 540)
    }
}

// MARK: - Shared helpers

/// A "Coming soon" tag for controls whose feature isn't wired up yet.
private struct ComingSoon: View {
    var body: some View {
        Text("Coming soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private extension View {
    /// Dim and disable a demo control while still showing it.
    func demo() -> some View {
        self.disabled(true).opacity(0.6)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("ByakaronStartAtLogin", store: ByakaronSettings.defaults) private var startAtLogin = false
    @AppStorage("ByakaronShowInMenuBar", store: ByakaronSettings.defaults) private var showInMenuBar = true
    @AppStorage("ByakaronUpdateChannel", store: ByakaronSettings.defaults) private var updateChannel = "stable"
    @AppStorage("ByakaronAutoUpdate", store: ByakaronSettings.defaults) private var autoUpdate = true

    var body: some View {
        Form {
            Section("Startup") {
                LabeledContent {
                    HStack { ComingSoon(); Toggle("", isOn: $startAtLogin).labelsHidden().demo() }
                } label: { Text("Start at login") }

                LabeledContent {
                    HStack { ComingSoon(); Toggle("", isOn: $showInMenuBar).labelsHidden().demo() }
                } label: { Text("Show in menu bar") }
            }

            Section {
                LabeledContent {
                    HStack { ComingSoon(); Toggle("", isOn: $autoUpdate).labelsHidden().demo() }
                } label: { Text("Automatically download updates") }

                Picker("Update channel", selection: $updateChannel) {
                    Text("Stable").tag("stable")
                    Text("Beta").tag("beta")
                }
                .demo()
            } header: {
                Text("Updates")
            } footer: {
             
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Typing

private struct TypingSettings: View {
    // Live: read by the IME engine.
    @AppStorage(ByakaronSettings.phoneticOnlyModeKey, store: ByakaronSettings.defaults)
    private var phoneticOnly = false

    // Demo: persisted, not consumed yet.
    @AppStorage("ByakaronAutoCorrect", store: ByakaronSettings.defaults) private var autoCorrect = true
    @AppStorage("ByakaronSmartDigits", store: ByakaronSettings.defaults) private var smartDigits = true
    @AppStorage("ByakaronAutoVowel", store: ByakaronSettings.defaults) private var autoVowel = true
    @AppStorage("ByakaronLearnWords", store: ByakaronSettings.defaults) private var learnWords = true
    @AppStorage("ByakaronKeyboardLayout", store: ByakaronSettings.defaults)
    
    private var keyboardLayout = "avro"
    
    var body: some View {
        Form {
            Section {
                Picker("Keyboard layout", selection: $keyboardLayout) {
                    Text("Avro Phonetic").tag("avro")
                    Text("Probhat").tag("probhat")
                    Text("National (Jatiyo)").tag("national")
                }
                .demo()
            } header: {
//                Text("Layout")
            } footer: {
                Text("Only Avro Phonetic is available today; other layouts come soon.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section {
                Toggle(isOn: $phoneticOnly) {
                    Text("Phonetic-only mode")
                    Text("Hides suggestions of words while typing.")
                }
            } header: {
                Text("Mode")
            }
            .onChange(of: phoneticOnly) { _, _ in
                // @AppStorage wrote the shared suite; tell the running IME.
                ByakaronSettings.broadcastChange()
            }

            Section("Corrections") {
                demoToggle("Auto-correct misspellings", $autoCorrect)
                demoToggle("Learn words as I type", $learnWords)
            }

            Section {
                demoToggle("Convert digits to Bangla numerals (০–৯)", $smartDigits)
                demoToggle("Smart vowel & conjunct handling", $autoVowel)
            } header: {
                Text("Bangla")
            }
        }
        .formStyle(.grouped)
    }

    private func demoToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        LabeledContent {
            HStack { ComingSoon(); Toggle("", isOn: binding).labelsHidden().demo() }
        } label: { Text(title) }
    }
}

// MARK: - Candidates

private struct CandidateSettings: View {
    // Live: read by CandidatePanel.
    @AppStorage(ByakaronSettings.candidateOrientationKey, store: ByakaronSettings.defaults)
    private var orientationRaw = ByakaronSettings.CandidateOrientation.horizontal.rawValue

    // Demo: persisted, not consumed yet.
    @AppStorage(ByakaronSettings.candidatesPerPageKey, store: ByakaronSettings.defaults)
    private var perPage = 9
    @AppStorage(ByakaronSettings.candidateFontSizeKey, store: ByakaronSettings.defaults)
    private var fontSize = 17.0
    @AppStorage("ByakaronShowEnglish", store: ByakaronSettings.defaults) private var showEnglish = true
    @AppStorage("ByakaronShowEmoji", store: ByakaronSettings.defaults) private var showEmoji = true

    private var orientation: Binding<ByakaronSettings.CandidateOrientation> {
        Binding(
            get: { ByakaronSettings.CandidateOrientation(rawValue: orientationRaw) ?? .horizontal },
            set: { orientationRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("List orientation", selection: orientation) {
                    ForEach(ByakaronSettings.CandidateOrientation.allCases) { o in
                        Text(o.label).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: orientationRaw) { _, _ in
                    ByakaronSettings.broadcastChange()
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Applies to the candidate popup the keyboard shows while you type.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("Layout") {
                LabeledContent("Candidates per page") {
                    HStack {
                        ComingSoon()
                        Stepper("\(perPage)", value: $perPage, in: 3...9).demo()
                    }
                }
                LabeledContent("Candidate font size") {
                    HStack {
                        ComingSoon()
                        Text("\(Int(fontSize)) pt").foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...28).frame(width: 140).demo()
                    }
                }
            }

            Section {
                demoToggle("Show English word in candidates", $showEnglish)
                demoToggle("Show emoji suggestions", $showEmoji)
            } header: {
                Text("Contents")
            }
        }
        .formStyle(.grouped)
    }

    private func demoToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        LabeledContent {
            HStack { ComingSoon(); Toggle("", isOn: binding).labelsHidden().demo() }
        } label: { Text(title) }
    }
}


// MARK: - Experimental

private struct ExperimentalSettings: View {
    // Live: read by the IME. When on, transliteration runs through the Zig
    // libbyakaron engine (inline phonetic) instead of riti.
    @AppStorage(ByakaronSettings.useZigTransliterationKey, store: ByakaronSettings.defaults)
    private var useZig = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $useZig) {
                    Text("Use Zig transliteration engine")
                    Text("Proof of concept. Routes typing through the new Zig engine "
                        + "(inline phonetic, no candidate list) instead of riti.")
                }
                .onChange(of: useZig) { _, _ in
                    // @AppStorage wrote the shared suite; tell the running IME to rebuild.
                    ByakaronSettings.broadcastChange()
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Experimental features may be unstable. Turn this off to return "
                    + "to the default riti engine with full suggestions.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettings().frame(width: 540)
}
#Preview("Typing") {
    TypingSettings().frame(width: 540)
}
#Preview("Suggestions") {
    CandidateSettings().frame(width: 540)
}
#Preview("Experimental") {
    ExperimentalSettings().frame(width: 540)
}
#endif
