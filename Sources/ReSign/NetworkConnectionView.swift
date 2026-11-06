import SwiftUI

struct NetworkConnectionView: View {
    @ObservedObject var model: AppModel
    let device: RememberedDevice
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var errorMessage: String?

    init(model: AppModel, device: RememberedDevice) {
        self.model = model
        self.device = device
        _address = State(initialValue: device.networkAddress ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通过 IP 连接").font(.title2.weight(.semibold))
            Text(device.name).font(.headline)
            Text("适用于校园网等无法自动发现设备的网络。设备需已通过 USB 信任这台 Mac，并在 Finder 中开启 Wi-Fi 显示。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("设备 IP 地址", text: $address, prompt: Text("例如 10.29.31.172"))
                .textFieldStyle(.roundedBorder)
            Text("在设备的“设置 → Wi-Fi → 当前网络 ⓘ”中查看地址。地址变化后需在此更新；留空保存可恢复自动发现。USB 连接始终优先。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存并连接") {
                    do {
                        try model.setNetworkAddress(address, for: device.id)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.isScanning)
            }
        }.padding(24).frame(width: 490)
    }
}
