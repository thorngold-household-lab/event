#if canImport(EventKit)
  import Foundation
  import XCTest

  @testable import event

  final class ReminderUpdateListTests: XCTestCase {
    func testUpdateParsesTargetList() throws {
      let command = try ReminderCommands.Update.parse([
        "--id", "reminder-id", "--list", "Personal",
      ])

      XCTAssertEqual(command.list, "Personal")
    }

    func testSameListDoesNotRequireMove() throws {
      XCTAssertFalse(
        ReminderService.requiresListMove(
          to: try ReminderService.validatedTargetListName("Personal"),
          currentListName: "Personal"
        )
      )
    }

    func testWhitespaceOnlyListIsRejected() {
      XCTAssertThrowsError(try ReminderService.validatedTargetListName("  \n "))
    }

    func testMovedReminderIdentityRequiresIdentifierOrTitleAndCreationDate() throws {
      let creationDate = Date(timeIntervalSince1970: 1_000)

      XCTAssertTrue(
        ReminderService.matchesMovedReminder(
          candidateIdentifier: "new-id",
          candidateTitle: "Pay rent",
          candidateCreationDate: creationDate,
          originalIdentifier: "old-id",
          originalTitle: "Pay rent",
          originalCreationDate: creationDate
        )
      )
      XCTAssertFalse(
        ReminderService.matchesMovedReminder(
          candidateIdentifier: "new-id",
          candidateTitle: "Pay rent",
          candidateCreationDate: nil,
          originalIdentifier: "old-id",
          originalTitle: "Pay rent",
          originalCreationDate: creationDate
        )
      )
      XCTAssertTrue(try reminderServiceSource().contains("if matches.count == 1"))
    }

    func testValidationAndTargetResolutionPrecedeMoveAttempt() throws {
      let source = try reminderServiceSource()
      let dueValidation = try XCTUnwrap(source.range(of: "let parsedDueDate"))
      let targetResolution = try XCTUnwrap(source.range(of: "let resolved = eventStore.calendars"))
      let moveAttempt = try XCTUnwrap(source.range(of: "let movedReminder = try targetList.map"))

      XCTAssertLessThan(dueValidation.lowerBound, moveAttempt.lowerBound)
      XCTAssertLessThan(targetResolution.lowerBound, moveAttempt.lowerBound)
    }

    func testTargetListNotFoundFailsBeforeMoveAttempt() throws {
      let source = try reminderServiceSource()
      let notFound = try XCTUnwrap(source.range(of: "List '\\(targetListName ?? \"\")' not found"))
      let moveAttempt = try XCTUnwrap(source.range(of: "let movedReminder = try targetList.map"))

      XCTAssertLessThan(notFound.lowerBound, moveAttempt.lowerBound)
    }

    func testFallbackResetsAndReidentifiesFromFreshTargetFetch() throws {
      let source = try reminderServiceSource()
      let failedSave = try XCTUnwrap(
        source.range(of: "try eventStore.save(reminder, commit: true)"))
      let reset = try XCTUnwrap(
        source.range(of: "eventStore.reset()", range: failedSave.upperBound..<source.endIndex)
      )
      let fallback = try XCTUnwrap(
        source.range(of: "try runAppleScriptMove", range: reset.upperBound..<source.endIndex)
      )
      let freshFetch = try XCTUnwrap(
        source.range(
          of: "let freshTargetList = eventStore.calendars",
          range: fallback.upperBound..<source.endIndex)
      )

      XCTAssertLessThan(failedSave.lowerBound, reset.lowerBound)
      XCTAssertLessThan(reset.lowerBound, fallback.lowerBound)
      XCTAssertLessThan(fallback.lowerBound, freshFetch.lowerBound)
      XCTAssertTrue(source.contains("if hasFieldEdits"))
    }

    func testNonMacOSListMoveIsRejected() {
      XCTAssertThrowsError(
        try ReminderCommands.Update.validateListOptionSupported(
          "Personal", eventKitAvailable: false
        )
      )
    }

    func testAppleScriptListEscaping() {
      XCTAssertEqual(
        ReminderService.escapeAppleScriptString(#"Team \ "Urgent""#),
        #"Team \\ \"Urgent\""#
      )
    }

    private func reminderServiceSource() throws -> String {
      var packageRoot = URL(fileURLWithPath: #filePath)
      for _ in 0..<4 {
        packageRoot.deleteLastPathComponent()
      }
      let sourceURL =
        packageRoot
        .appendingPathComponent("Sources/event/Services/ReminderService.swift")
      return try String(contentsOf: sourceURL, encoding: .utf8)
    }
  }
#endif
