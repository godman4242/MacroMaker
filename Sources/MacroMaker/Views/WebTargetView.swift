import SwiftUI

struct WebTargetView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingTab = false

    var body: some View {
        @Bindable var web = model.webClicker
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Browser", selection: $web.settings.browser) {
                        ForEach(Browser.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("URL contains") {
                        HStack(spacing: 6) {
                            TextField("URL", text: $web.settings.urlMatch, prompt: Text("example.com/game"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Button("Choose Tab…") {
                                web.loadTabs()
                                isChoosingTab = true
                            }
                            .popover(isPresented: $isChoosingTab, arrowEdge: .bottom) {
                                TabPicker(web: web) { tab in
                                    web.settings.urlMatch = tab.url
                                    isChoosingTab = false
                                }
                            }
                        }
                    }
                } header: {
                    Text("Browser tab")
                } footer: {
                    Text("Clicks go to the first open tab whose address contains this text. The tab can be in the background, and you can keep using other apps.")
                }

                Section {
                    Picker("Find element by", selection: $web.settings.locatorKind) {
                        Text("CSS selector").tag(WebTargetSettings.LocatorKind.css)
                        Text("XPath").tag(WebTargetSettings.LocatorKind.xpath)
                        Text("Coordinates").tag(WebTargetSettings.LocatorKind.coordinates)
                    }
                    .pickerStyle(.segmented)
                    switch web.settings.locatorKind {
                    case .css:
                        TextField("Selector", text: $web.settings.cssSelector, prompt: Text("#buy-button"))
                            .monospaced()
                    case .xpath:
                        TextField("XPath", text: $web.settings.xpath, prompt: Text("//button[text()='Buy']"))
                            .monospaced()
                    case .coordinates:
                        NumberField("X", value: $web.settings.x, unit: "px", range: 0...100_000)
                        NumberField("Y", value: $web.settings.y, unit: "px", range: 0...100_000)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        statusView(web.status)
                        Spacer()
                        Button("Test Click") { web.testClick() }
                            .disabled(web.session.phase.isActive)
                    }
                } header: {
                    Text("Element to click")
                } footer: {
                    Text(locatorTip(web.settings.locatorKind))
                }

                Section("Timing") {
                    NumberField("Click every", value: $web.settings.intervalMs, unit: "ms",
                                range: WebClicker.minimumIntervalMs...WebClicker.maximumIntervalMs, step: 100)
                }

                Section("Shortcut") {
                    LabeledContent("Start / stop") {
                        HotkeyField(action: .toggleWebTarget)
                    }
                }

                Section("One-time setup for \(web.settings.browser.displayName)") {
                    Label {
                        Text("Allow scripts: \(web.settings.browser.javaScriptSettingPath).").wrapsText()
                    } icon: {
                        Image(systemName: "1.circle.fill")
                    }
                    Label {
                        Text("On the first click, macOS asks whether Macro Maker may control \(web.settings.browser.displayName). Click Allow.").wrapsText()
                    } icon: {
                        Image(systemName: "2.circle.fill")
                    }
                    HStack {
                        Spacer()
                        Button("Open Automation Settings") { model.permissions.open(.automation) }
                    }
                }
            }
            .formStyle(.grouped)

            RunControls(session: web.session,
                        startTitle: "Start Clicking in Browser",
                        hotkey: .toggleWebTarget,
                        detail: "\(web.clickCount.formatted()) clicks",
                        usesCountdown: false,
                        isStartDisabled: web.problem != nil) {
                web.toggle(.button)
            }
        }
    }

    @ViewBuilder private func statusView(_ status: WebClicker.Status) -> some View {
        switch status {
        case .idle:
            Text("Use Test Click to check the element is found.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .success(message):
            StatusMessage(kind: .success, text: message)
        case let .warning(message):
            StatusMessage(kind: .warning, text: message)
        case let .error(message):
            StatusMessage(kind: .error, text: message)
        }
    }

    private func locatorTip(_ kind: WebTargetSettings.LocatorKind) -> String {
        switch kind {
        case .css:
            "Tip: right-click the element in the browser ▸ Inspect, then right-click the highlighted code ▸ Copy ▸ Copy selector (Chrome) or Selector Path (Safari)."
        case .xpath:
            "Tip: right-click the element ▸ Inspect, then right-click the highlighted code ▸ Copy ▸ Copy XPath (Chrome) or XPath (Safari)."
        case .coordinates:
            "CSS pixels from the top-left of the page's visible area. The element under that point is clicked, even if the tab is hidden."
        }
    }
}

/// Popover listing the browser's open tabs.
private struct TabPicker: View {
    let web: WebClicker
    let choose: (BrowserTab) -> Void

    var body: some View {
        Group {
            if let error = web.tabsError {
                StatusMessage(kind: .warning, text: error)
                    .padding()
                    .frame(width: 360, alignment: .leading)
            } else {
                List(web.tabs) { tab in
                    Button {
                        choose(tab)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title.isEmpty ? tab.url : tab.title).lineLimit(1)
                            Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 440, height: 300)
            }
        }
    }
}
