import XCTest
@testable import Hermes

final class ChatTabTests: XCTestCase {
    func testNamesNormalizeAndRejectOversizedChanges() throws {
        var metadata = ChatTabMetadata()
        try metadata.rename("  Work\n  project ")
        XCTAssertEqual(metadata.customTitle, "Work project")
        XCTAssertThrowsError(try metadata.rename(String(repeating: "a", count: 81)))
        XCTAssertEqual(metadata.customTitle, "Work project")
        try metadata.rename(String(repeating: "a", count: 80))
        XCTAssertEqual(metadata.customTitle?.count, 80)
        try metadata.rename(" \n ")
        XCTAssertNil(metadata.customTitle)
    }

    func testLegacyChatAndRemoteSnapshotsRemainCompatible() throws {
        let snapshot = try JSONDecoder().decode(
            ChatStore.Snapshot.self, from: Data(#"{"turns":[]}"#.utf8)
        )
        XCTAssertNil(snapshot.tabMetadata)
        let remote = try JSONDecoder().decode(
            CantripRemoteSession.self, from: Data(#"""
            {"id":"a","title":"Old chat","workdir":"/tmp","isStreaming":false,
             "canResume":false,"councilMode":false,"queuedCount":0}
            """#.utf8)
        )
        XCTAssertNil(remote.isLocked)
        XCTAssertNil(remote.customTitle)
        XCTAssertNil(remote.supportsTabMetadata)
    }

    @MainActor
    func testLocalNamesAndLocksSurviveRelaunchAndLaneSwitches() throws {
        ChatStore.clear(for: .copilot)
        ChatStore.clear(for: .local)
        defer {
            ChatStore.clear(for: .copilot)
            ChatStore.clear(for: .local)
        }
        let env = HermesEnv()
        env.select(.copilot)
        let vm = ChatViewModel(env: env, remote: CantripRemoteModel(), voice: VoiceController())
        vm.turns = [ChatTurn(role: .user, text: "Automatic name", executionLane: .copilot)]
        vm.renameTab("Project")
        vm.setTabLocked(true)
        let snapshot = ChatStore.load(for: .copilot)
        XCTAssertEqual(snapshot.tabMetadata?.customTitle, "Project")
        XCTAssertEqual(snapshot.tabMetadata?.isLocked, true)

        vm.newConversation()
        XCTAssertEqual(vm.turns.first?.text, "Automatic name")
        XCTAssertNotNil(vm.tabActionError)
        XCTAssertEqual(ChatStore.load(for: .copilot).conversationID, snapshot.conversationID)

        vm.switchLane(to: .local)
        XCTAssertFalse(vm.isTabLocked)
        vm.renameTab("Private work")
        vm.setTabLocked(true)
        vm.newConversation()
        XCTAssertEqual(vm.tabTitle, "Private work", "Even an empty locked chat is protected")
        vm.switchLane(to: .copilot)
        XCTAssertEqual(vm.tabTitle, "Project")
        XCTAssertTrue(vm.isTabLocked)

        let restored = ChatViewModel(env: env, remote: CantripRemoteModel(), voice: VoiceController())
        XCTAssertEqual(restored.tabTitle, "Project")
        XCTAssertTrue(restored.isTabLocked)
        restored.renameTab(" \n ")
        XCTAssertEqual(restored.tabTitle, "Automatic name")
        restored.setTabLocked(false)
        restored.newConversation()
        XCTAssertTrue(restored.turns.isEmpty)
        XCTAssertFalse(restored.isTabLocked)
    }
}
