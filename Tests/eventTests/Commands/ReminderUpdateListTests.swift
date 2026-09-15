#if canImport(EventKit)
  import XCTest

  @testable import event

  final class ReminderUpdateListTests: XCTestCase {
    func testUpdateParsesTargetList() throws {
      let command = try ReminderCommands.Update.parse([
        "--id", "reminder-id", "--list", "Personal",
      ])

      XCTAssertEqual(command.list, "Personal")
    }

    func testAppleScriptListEscaping() {
      XCTAssertEqual(
        ReminderService.escapeAppleScriptString(#"Team \ "Urgent""#),
        #"Team \\ \"Urgent\""#
      )
    }
  }
#endif
