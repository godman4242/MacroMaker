import SwiftUI

struct AutoClickerView: View {
    @Environment(AppModel.self) private var model
    @State private var directAppTestResult: String?

    var body: some View {
        @Bindable var clicker = model.autoClicker
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Mouse button", selection: $clicker.settings.button) {
                        ForEach(MouseButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    IntervalField(milliseconds: $clicker.settings.intervalMs,
                                  unit: $clicker.settings.intervalUnit)
                    Picker("Each event is a", selection: $clicker.settings.clickCountPerEvent) {
                        ForEach(AutoClickerSettings.ClickCount.allCases) { count in
                            Text(count.title).tag(count)
                        }
                    }
                    NumberField("Clicks per interval", value: $clicker.settings.burstSize,
                                unit: "", range: 1...10)
                    Toggle("Add a random offset to each interval", isOn: $clicker.settings.randomizeInterval)
                    if clicker.settings.randomizeInterval {
                        NumberField("Offset up to ±", value: $clicker.settings.randomOffsetMs,
                                    unit: "ms", range: 0...60_000, step: 5)
                    }
                } header: {
                    Text("Clicking")
                } footer: {
                    Text(rateDescription(clicker.settings))
                }

                Section("Position") {
                    Picker("Click at", selection: $clicker.settings.target) {
                        Text("Wherever the cursor is").tag(AutoClickerSettings.Target.cursor)
                        Text("A fixed point on screen").tag(AutoClickerSettings.Target.fixedPoint)
                        Text("A random point inside a rectangle").tag(AutoClickerSettings.Target.region)
                        Text("Inside a specific app (background)").tag(AutoClickerSettings.Target.directApp)
                    }
                    .pickerStyle(.radioGroup)
                    if clicker.settings.target == .directApp {
                        StatusMessage(kind: .info, text: "The point is remembered as a spot inside the app’s window — if the window moves, clicks move with it.")
                    }
                    switch clicker.settings.target {
                    case .cursor:
                        EmptyView()
                    case .fixedPoint:
                        fixedPointRows(clicker: clicker)
                    case .region:
                        regionRows(clicker: clicker)
                    case .directApp:
                        directAppRows(clicker: clicker)
                    }
                    Toggle("Vary the point by up to ±", isOn: $clicker.settings.jitterEnabled)
                    if clicker.settings.jitterEnabled {
                        NumberField("Variation", value: $clicker.settings.jitterPx,
                                    unit: "px", range: 0...200, step: 1)
                    }
                    Toggle("Move the cursor back after each click", isOn: $clicker.settings.restoreCursor)
                }

                Section("Stop automatically") {
                    Toggle("After a number of clicks", isOn: $clicker.settings.stopAfterClicks)
                    if clicker.settings.stopAfterClicks {
                        NumberField("Clicks", value: $clicker.settings.maxClicks, unit: "", range: 1...10_000_000)
                    }
                    Toggle("After a time limit", isOn: $clicker.settings.stopAfterDuration)
                    if clicker.settings.stopAfterDuration {
                        NumberField("Time limit", value: $clicker.settings.maxDurationSeconds,
                                    unit: "sec", range: 0.1...86_400)
                    }
                    Toggle("When the frontmost app changes", isOn: $clicker.settings.stopOnFrontmostChange)
                    if clicker.settings.stopOnFrontmostChange {
                        Text("The run remembers which app is in front when it starts and stops the moment another app comes forward.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Until the stop shortcut", isOn: $clicker.settings.stopOnHotkey)
                    if clicker.settings.stopOnHotkey {
                        Text("The run ignores the limits above and repeats until you press the Stop-the-Current-Run shortcut (Settings ▸ Keyboard shortcuts, default F6).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Pause when I use the mouse or keyboard", isOn: $clicker.settings.pauseOnRealInput)
                    if clicker.settings.pauseOnRealInput {
                        NumberField("Resume after idle", value: $clicker.settings.autoResumeSeconds,
                                    unit: "sec", range: 1...600, step: 1)
                        Text("Your own key presses and clicks pause the run; after this many quiet seconds it starts again. Macro Maker's own clicks don't count.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Starting") {
                    NumberField("Extra countdown", value: $clicker.settings.delayedStartSeconds,
                                unit: "sec", range: 0...600, step: 1)
                    Toggle("Click only while the shortcut is held", isOn: $clicker.settings.holdToClick)
                    if clicker.settings.holdToClick {
                        Text("Press and hold \(model.hotkeys.label(for: .toggleAutoClicker) ?? "the shortcut") to click; releasing the keys stops the run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HumanizeSection(settings: $clicker.settings.humanizer)

                Section("Shortcut") {
                    LabeledContent("Start / stop clicking") {
                        HotkeyField(action: .toggleAutoClicker)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(clicker.session.phase.isActive)

            if let warning = clicker.runWarning {
                // No phase condition. The "target app quit" message is reported with
                // finished: true, and the same main-actor hop then sets the phase to .idle — so
                // requiring a non-idle phase meant SwiftUI never observed a state where it was
                // visible, and background clicking stopped with no explanation at all. Both
                // toggle() and the session's stop hook clear runWarning when a run ends, so nothing goes stale.
                StatusMessage(kind: .warning, text: warning)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            RunControls(session: clicker.session,
                        startTitle: "Start Clicking",
                        hotkey: .toggleAutoClicker,
                        detail: "\(clicker.clickCount.formatted()) clicks",
                        resume: clicker.settings.pauseOnRealInput ? { clicker.resume() } : nil) {
                clicker.toggle(.button)
            }
        }
    }

    @ViewBuilder private func fixedPointRows(clicker: AutoClicker) -> some View {
        @Bindable var clicker = clicker
        NumberField("X", value: $clicker.settings.x, unit: "pt", range: -20_000...20_000)
        NumberField("Y", value: $clicker.settings.y, unit: "pt", range: -20_000...20_000)
        pickRow(instruction: "Points from the top-left corner of the main display.",
                button: "Pick with Cursor…", capturing: "Hover over the target…",
                isCapturing: clicker.activePick == .point) {
            clicker.pickFixedPoint()
        }
    }

    @ViewBuilder private func regionRows(clicker: AutoClicker) -> some View {
        @Bindable var clicker = clicker
        NumberField("Top-left X", value: Binding(get: { clicker.settings.region.x },
                                                 set: { clicker.settings.region.x = $0 }),
                    unit: "pt", range: -20_000...20_000)
        NumberField("Top-left Y", value: Binding(get: { clicker.settings.region.y },
                                                 set: { clicker.settings.region.y = $0 }),
                    unit: "pt", range: -20_000...20_000)
        NumberField("Width", value: Binding(get: { clicker.settings.region.width },
                                            set: { clicker.settings.region.width = $0 }),
                    unit: "pt", range: 1...20_000)
        NumberField("Height", value: Binding(get: { clicker.settings.region.height },
                                             set: { clicker.settings.region.height = $0 }),
                    unit: "pt", range: 1...20_000)
        pickRow(instruction: "Hover over one corner of the rectangle.",
                button: "Pick Corner 1…", capturing: "Corner 1 capturing…",
                isCapturing: clicker.activePick == .regionCorner1) {
            clicker.pickRegionCorner(false)
        }
        pickRow(instruction: "Then hover over the opposite corner.",
                button: "Pick Corner 2…", capturing: "Corner 2 capturing…",
                isCapturing: clicker.activePick == .regionCorner2) {
            clicker.pickRegionCorner(true)
        }
    }

    @ViewBuilder private func directAppRows(clicker: AutoClicker) -> some View {
        @Bindable var clicker = clicker
        TargetAppPicker(bundleID: $clicker.settings.directAppBundleID)
        if let problem = clicker.directAppProblem {
            StatusMessage(kind: .error, text: problem)
        } else {
            StatusMessage(kind: .info, text: clicker.directAppStatus)
        }
        NumberField("Point X", value: $clicker.settings.directAppX, unit: "pt", range: -20_000...20_000)
        NumberField("Point Y", value: $clicker.settings.directAppY, unit: "pt", range: -20_000...20_000)
        pickRow(instruction: "Hover over the spot inside the target app’s window.",
                button: "Pick with Cursor…", capturing: "Hover over the target window…",
                isCapturing: clicker.activePick == .directAppPoint) {
            clicker.pickDirectAppPoint()
        }
        HStack {
            Button("Test Click") { directAppTestResult = clicker.testClick() }
                .help("Posts one click at the chosen point")
            if let result = directAppTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text("The app can be behind other windows and your cursor never moves — clicks are delivered straight to the app’s process, aimed at whichever of its windows is on top, re-aimed if the window moves. The catch: apps that read the raw input device instead of the event queue (many games, e.g. Roblox) ignore these clicks entirely.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func pickRow(instruction: String, button: String, capturing: String,
                                      isCapturing: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            if isCapturing, let secondsLeft = model.autoClicker.pickCountdown {
                StatusMessage(kind: .info, text: "\(capturing) \(secondsLeft)")
                Spacer()
                Button("Cancel") { model.autoClicker.cancelPick() }
            } else {
                Text(instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(button, action: action)
            }
        }
    }

    private func rateDescription(_ settings: AutoClickerSettings) -> String {
        var rate = ClickRate.describe(intervalMs: settings.intervalMs, burstSize: settings.burstSize)
        if settings.burstSize > 1 {
            rate += " \(settings.burstSize) clicks each interval"
        }
        if settings.randomizeInterval {
            rate += ", varied by up to ±\(Int(settings.randomOffsetMs)) ms"
        }
        return rate + "."
    }
}
