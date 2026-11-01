import AppKit
import SwiftUI

extension SessionTabTests {
    /// Settings stays inside its pane at the pane's narrowest and default widths: MCP Servers (long
    /// names, both tags, status text and Connect, all four backend switches), Version, and the
    /// whole column for every backend.
    @MainActor
    static func testMCPSettingsFitThePane() async {
        let probe = NSHostingController(rootView: Color.clear.frame(width: 400, height: 1))
        precondition(probe.sizeThatFits(in: CGSize(width: 200, height: 100)).width > 200, "The measure reports overflow")

        let servers = [
            MCPServer(name: "browser_tools", command: "/usr/bin/python3"),
            MCPServer(name: "vault", command: "/usr/bin/python3", tools: ["status", "get"]),
            MCPServer(name: "design-library", url: "https://mcp.example.com/mcp", oauth: true),
            MCPServer(name: "flows", url: "https://flows.example.com/mcp", secretHeaders: ["Authorization"]),
            MCPServer(name: "errors", url: "https://errors.example.com/mcp", oauth: true, disabledBackends: ["Codex"]),
        ]
        let hub = MCPServerHub(signIns: MCPSignIns(secrets: .memory()),
                               snapshot: MCPRegistry.Snapshot(servers: servers, importedAt: Date()))
        await hub.refreshStates()
        precondition(MCPServerRow.statusText(servers[2], hub.states["design-library"]) == "Not signed in")
        precondition(MCPServerRow.statusText(servers[3], hub.states["flows"]) == "Credentials in keychain")

        var report = CantripVersionReport(runningIdentity: "v1.1.12-18-gc0873c6-dirty", runningDate: "2026-10-31T20:16:00Z")
        report.latest = CantripBuildVersion(identity: "v1.1.12-12-g8f2e45b")
        report.latestSubject = "Pin Cantrip Gateway Mac with Codex's limits on the usage screen and a much longer subject line"
        report.latestDate = Date()
        report.source = CantripBuildVersion(identity: "v1.1.12-19-gabc1234")
        report.runningBehind = 0
        // The pane is 280-560 wide (330 by default) and Settings pads its content by 16 on each side.
        for pane in [280.0, 330.0] {
            let width = pane - 32
            let mcp = NSHostingController(rootView: MCPServersView(hub: hub))
                .sizeThatFits(in: CGSize(width: width, height: 10_000))
            precondition(mcp.width <= width + 0.5, "MCP Servers is \(mcp.width) wide in a \(width) column")
            let versions = NSHostingController(rootView: CantripVersionContent(
                report: report, isChecking: false, busySessions: 0,
                onCheck: {}, onUpdate: {}, onRestart: {}))
                .sizeThatFits(in: CGSize(width: width, height: 10_000))
            precondition(versions.width <= width + 0.5, "Version is \(versions.width) wide in a \(width) column")
        }

        // The whole column, for every backend, with its optional sections showing. One view that
        // can't shrink makes the column wider than the pane and pushes every row's right edge out.
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.remoteControlEnabled, settings.cantripHomeEnabled)
        defer {
            (settings.backend, settings.memoryEnabled, settings.remoteControlEnabled, settings.cantripHomeEnabled) = saved
        }
        settings.memoryEnabled = true
        settings.remoteControlEnabled = true
        settings.cantripHomeEnabled = true
        for backend in BackendKind.allCases {
            settings.backend = backend
            for pane in [280.0, 330.0] {
                let column = NSHostingController(rootView: SettingsView(busySessions: 0, onUpdate: {}).settingsContent)
                    .sizeThatFits(in: CGSize(width: pane, height: 20_000))
                precondition(column.width <= pane + 0.5, "Settings for \(backend.rawValue) is \(column.width) wide in a \(pane) pane")
            }
        }
        print("MCP settings layout: Settings, MCP Servers and Version fit the settings pane at 280 and 330 wide")
    }
}
