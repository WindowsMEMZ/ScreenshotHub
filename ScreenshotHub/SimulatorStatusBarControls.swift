import SwiftUI

struct SimulatorStatusBarControls: View {
    let feed: SimulatorFeed
    
    @State private var configuration = SimulatorStatusBarConfiguration.load()
    @State private var isUpdating = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    
    var body: some View {
        Section {
            Group {
                TextField("Time", text: $configuration.time, prompt: Text("9:41"))
                Picker("Data Network", selection: $configuration.dataNetwork) {
                    ForEach(SimulatorStatusBarConfiguration.DataNetwork.allCases) { network in
                        Text(network.label).tag(network)
                    }
                }
                Picker("Wi-Fi Status", selection: $configuration.wifiMode) {
                    ForEach(SimulatorStatusBarConfiguration.WiFiMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper(value: $configuration.wifiBars, in: 0...3) {
                    Text("Wi-Fi Signal")
                    Text("\(configuration.wifiBars) of 3").foregroundStyle(.secondary)
                }
                Picker("Cellular Status", selection: $configuration.cellularMode) {
                    ForEach(SimulatorStatusBarConfiguration.CellularMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper(value: $configuration.cellularBars, in: 0...4) {
                    Text("Cellular Signal")
                    Text("\(configuration.cellularBars) of 4").foregroundStyle(.secondary)
                }
                TextField("Carrier", text: $configuration.operatorName, prompt: Text("Leave blank to hide"))
                Picker("Battery Status", selection: $configuration.batteryState) {
                    ForEach(SimulatorStatusBarConfiguration.BatteryState.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                Stepper(value: $configuration.batteryLevel, in: 0...100) {
                    Text("Battery Level")
                    Text("\(configuration.batteryLevel)%").foregroundStyle(.secondary)
                }
                Button(isUpdating ? "Updating…" : "Apply to Simulator") { updateStatusBar(clearing: false) }
                Button("Reset Status Bar") { updateStatusBar(clearing: true) }
            }
            .disabled(feed.selectedDeviceID == nil || isUpdating)
        } header: {
            Label("Simulator Status Bar", systemImage: "cellularbars")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes apply to the selected simulator and appear in the preview and exported screenshots.")
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if let resultMessage {
                    Text(resultMessage)
                }
            }
        }
        .onChange(of: configuration) { _, configuration in
            configuration.save()
        }
        .onChange(of: feed.selectedDeviceID) { _, _ in
            resultMessage = nil
            errorMessage = nil
        }
    }
    
    private func updateStatusBar(clearing: Bool) {
        guard let deviceID = feed.selectedDeviceID, !isUpdating else { return }
        let configuration = configuration
        isUpdating = true
        resultMessage = nil
        errorMessage = nil
        Task {
            defer { isUpdating = false }
            do {
                if clearing {
                    try await feed.clearStatusBar(deviceID: deviceID)
                } else {
                    try await feed.applyStatusBar(configuration, deviceID: deviceID)
                }
                guard feed.selectedDeviceID == deviceID else { return }
                resultMessage = clearing ? "Status bar reset." : "Status bar overrides applied."
            } catch is CancellationError {
            } catch {
                guard feed.selectedDeviceID == deviceID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
