#if canImport(EventKit)
  import EventKit
  import EventModels
  import XCTest

  @testable import event

  /// Service-level tests that operate on in-memory `EKReminder` objects.
  /// `EKReminder` can be constructed without Reminders permission as long as we
  /// never call `eventStore.save(...)`.
  final class ReminderServiceTests: XCTestCase {

    /// Shared store — `EKEventStore()` is non-trivial to construct, and these tests
    /// only need it as the required `EKReminder.init` dependency, never as an I/O sink.
    private lazy var store = EKEventStore()

    // MARK: - Helpers

    private func makeReminder(title: String) -> EKReminder {
      let reminder = EKReminder(eventStore: store)
      reminder.title = title
      return reminder
    }

    private func makeLocationAlarm(title: String) -> EKAlarm {
      LocationTrigger(
        title: title,
        latitude: 22.5431,
        longitude: 114.0579,
        radius: 100,
        proximity: .enter
      ).toEKAlarm()
    }

    // MARK: - applyURL

    func testApplyURLPersistsValidURLOnReminder() {
      let reminder = makeReminder(title: "URL reminder")

      ReminderService.applyURL("https://example.com/reminder", to: reminder)

      XCTAssertEqual(reminder.url?.absoluteString, "https://example.com/reminder")
    }

    func testApplyURLLeavesReminderUnchangedWhenURLIsAbsent() {
      let reminder = makeReminder(title: "No URL")
      reminder.url = URL(string: "https://example.com/existing")

      ReminderService.applyURL(nil, to: reminder)

      XCTAssertEqual(reminder.url?.absoluteString, "https://example.com/existing")
    }

    func testURLPersistenceUsesPrimaryCreateAndUpdateSaves() throws {
      let testFile = URL(fileURLWithPath: #filePath)
      let packageRoot =
        testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let serviceURL =
        packageRoot
        .appendingPathComponent("Sources/event/Services/ReminderService.swift")
      let source = try String(contentsOf: serviceURL, encoding: .utf8)

      let postProcess = try sourceSection(
        source,
        from: "private func postProcessReminder(",
        to: "/// Create reminder via EventKit"
      )
      let create = try sourceSection(
        source,
        from: "private func createViaEventKit(",
        to: "/// Update reminder via EventKit"
      )
      let update = try sourceSection(
        source,
        from: "private func updateViaEventKit(",
        to: "static func validatedTargetListName("
      )

      XCTAssertFalse(postProcess.contains("eventStore.save"))
      XCTAssertLessThan(
        try XCTUnwrap(create.range(of: "Self.applyURL(url, to: ekReminder)")?.lowerBound),
        try XCTUnwrap(create.range(of: "try eventStore.save(ekReminder, commit: true)")?.lowerBound)
      )
      XCTAssertLessThan(
        try XCTUnwrap(update.range(of: "Self.applyURL(url, to: ekReminder)")?.lowerBound),
        try XCTUnwrap(update.range(of: "let hasFieldEdits")?.lowerBound)
      )
      XCTAssertTrue(update.contains("|| url != nil"))
    }

    private func sourceSection(_ source: String, from start: String, to end: String) throws
      -> String
    {
      let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
      let endIndex = try XCTUnwrap(
        source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
      return String(source[startIndex..<endIndex])
    }

    // MARK: - removeLocationAlarms

    func testRemoveLocationAlarmsPreservesTimeBasedAlarms() throws {
      // Given a reminder with one time-based alarm and one location-based alarm…
      let reminder = makeReminder(title: "Mixed alarms")
      reminder.addAlarm(EKAlarm(relativeOffset: -600))  // 10 minutes before
      reminder.addAlarm(makeLocationAlarm(title: "Home"))
      XCTAssertEqual(reminder.alarms?.count, 2)

      // When the location alarms are removed…
      reminder.removeLocationAlarms()

      // …only the time-based alarm remains, with its offset intact.
      let remaining = reminder.alarms ?? []
      XCTAssertEqual(remaining.count, 1)
      XCTAssertNil(remaining.first?.structuredLocation)
      XCTAssertEqual(remaining.first?.relativeOffset, -600)
    }

    func testRemoveLocationAlarmsHandlesNoAlarms() {
      // Given a reminder with no alarms at all, the helper is a no-op.
      let reminder = makeReminder(title: "No alarms")

      reminder.removeLocationAlarms()

      XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
    }

    func testRemoveLocationAlarmsHandlesOnlyLocationAlarms() {
      // Given a reminder with only location-based alarms, all of them are cleared.
      let reminder = makeReminder(title: "Location only")
      reminder.addAlarm(makeLocationAlarm(title: "Home"))
      reminder.addAlarm(makeLocationAlarm(title: "Office"))
      XCTAssertEqual(reminder.alarms?.count, 2)

      reminder.removeLocationAlarms()

      XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
    }

    func testRemoveLocationAlarmsHandlesMultipleLocationAlarms() {
      // Given a reminder with one time-based alarm and two location-based alarms,
      // every location alarm is removed but the time-based one survives.
      let reminder = makeReminder(title: "Multiple location alarms")
      reminder.addAlarm(EKAlarm(relativeOffset: -300))
      reminder.addAlarm(makeLocationAlarm(title: "Home"))
      reminder.addAlarm(makeLocationAlarm(title: "Office"))
      XCTAssertEqual(reminder.alarms?.count, 3)

      reminder.removeLocationAlarms()

      let remaining = reminder.alarms ?? []
      XCTAssertEqual(remaining.count, 1)
      XCTAssertNil(remaining.first?.structuredLocation)
      XCTAssertEqual(remaining.first?.relativeOffset, -300)
    }
  }
#endif
