import SwiftUI

/// Quick SSH test view for debugging connections
///
/// Allows direct SSH connection testing without creating a server profile.
struct SSHTestView: View {
    @State private var host: String = "localhost"
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var connectionStatus: String = "Not connected"
    @State private var outputText: String = ""
    @State private var transport: CitadelSSHTransport?
    @State private var isConnecting = false
    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Connection form
            Form {
                Section("Connection") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                }

                Section("Status") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                    }

                    if isConnecting {
                        ProgressView()
                    }
                }

                Section {
                    Button(transport != nil ? "Disconnect" : "Connect") {
                        if transport != nil {
                            disconnect()
                        } else {
                            connect()
                        }
                    }
                    .disabled(isConnecting || username.isEmpty || password.isEmpty)
                }
            }
            .frame(height: 350)

            // Terminal output area
            VStack(spacing: 8) {
                Text("Terminal Output")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                ScrollView {
                    Text(outputText.isEmpty ? "(No output yet)" : outputText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: .infinity)
                .background(Color.black)
                .foregroundColor(.green)
                .cornerRadius(8)
                .padding(.horizontal)

                // Input field when connected
                if transport != nil {
                    HStack {
                        TextField("Command...", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Send") {
                            sendInput()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputText.isEmpty)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("SSH Test")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear {
            disconnect()
        }
    }

    private var statusColor: Color {
        switch connectionStatus {
        case "Connected": return .green
        case "Connecting...": return .yellow
        case "Not connected", "Disconnected": return .gray
        default: return .red
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        connectionStatus = "Connecting..."
        outputText = ""

        let config = TransportConfig(
            host: host,
            port: UInt16(port) ?? 22,
            username: username,
            authMethod: .password(password),
            terminalCols: 80,
            terminalRows: 24
        )

        let newTransport = CitadelSSHTransport(config: config)

        // Initialize streams before connecting (fixes race condition)
        newTransport.initializeStreams()

        self.transport = newTransport

        // Start data reading task first
        Task {
            for await data in newTransport.dataStream {
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run {
                        outputText += text
                    }
                }
            }

            await MainActor.run {
                connectionStatus = "Disconnected"
                transport = nil
            }
        }

        // Then connect
        Task {
            do {
                try await newTransport.connect()

                await MainActor.run {
                    connectionStatus = "Connected"
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    connectionStatus = "Error: \(error.localizedDescription)"
                    isConnecting = false
                    transport = nil
                }
            }
        }
    }

    private func disconnect() {
        guard let transport = transport else { return }

        Task {
            try? await transport.disconnect()
            await MainActor.run {
                self.transport = nil
                connectionStatus = "Disconnected"
            }
        }
    }

    private func sendInput() {
        guard let transport = transport, !inputText.isEmpty else { return }

        let text = inputText + "\n"
        inputText = ""

        Task {
            if let data = text.data(using: .utf8) {
                try? await transport.send(data)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SSHTestView()
    }
}
