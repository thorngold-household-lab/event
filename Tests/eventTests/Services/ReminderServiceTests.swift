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

    func testManagedURLFallbackRoundTripsWithoutChangingExposedNotes() {
      let stored = ReminderURLStorage.storing(
        "https://example.com/reminder?a=1&b=2", in: "User-authored notes"
      )
      let exposed = ReminderURLStorage.exposedValues(notes: stored, nativeURL: nil)

      XCTAssertEqual(exposed.notes, "User-authored notes")
      XCTAssertEqual(exposed.url, "https://example.com/reminder?a=1&b=2")
    }

    func testManagedURLFallbackHandlesMissingNotesAndReplacement() {
      let initial = ReminderURLStorage.storing("https://example.com/old", in: nil)
      let replaced = ReminderURLStorage.storing("https://example.com/new", in: initial)
      let exposed = ReminderURLStorage.exposedValues(notes: replaced, nativeURL: nil)

      XCTAssertNil(exposed.notes)
      XCTAssertEqual(exposed.url, "https://example.com/new")
    }

    func testManagedURLTakesPrecedenceOverStaleNativeURL() {
      let stored = ReminderURLStorage.storing("https://example.com/fallback", in: "Notes")
      let exposed = ReminderURLStorage.exposedValues(
        notes: stored, nativeURL: URL(string: "https://example.com/native")
      )

      XCTAssertEqual(exposed.notes, "Notes")
      XCTAssertEqual(exposed.url, "https://example.com/fallback")
    }

    func testNativeURLIsUsedWhenManagedURLIsAbsent() {
      let exposed = ReminderURLStorage.exposedValues(
        notes: "Notes", nativeURL: URL(string: "https://example.com/native")
      )

      XCTAssertEqual(exposed.notes, "Notes")
      XCTAssertEqual(exposed.url, "https://example.com/native")
    }

    func testURLPersistenceCommitsManagedCopyBeforeNativeCompatibilitySave() throws {
      let testFile = URL(fileURLWithPath: #filePath)
      let packageRoot =
        testFile
        .deletingLastPathComponent()
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
      let createManaged = try XCTUnwrap(
        create.range(of: "ReminderURLStorage.storing(url, in: ekReminder.notes)")?.lowerBound
      )
      let createPrimarySave = try XCTUnwrap(
        create.range(of: "try eventStore.save(ekReminder, commit: true)")?.lowerBound
      )
      let createNativeSave = try XCTUnwrap(
        create.range(of: "persistNativeURLIfSupported(url, on: ekReminder)")?.lowerBound
      )
      XCTAssertLessThan(createManaged, createPrimarySave)
      XCTAssertLessThan(createPrimarySave, createNativeSave)

      let updateManaged = try XCTUnwrap(
        update.range(
          of: "ReminderURLStorage.storing(url, in: ekReminder.notes)", options: .backwards
        )?.lowerBound
      )
      let updatePrimarySave = try XCTUnwrap(
        update.range(of: "try eventStore.save(ekReminder, commit: true)")?.lowerBound
      )
      let updateNativeSave = try XCTUnwrap(
        update.range(of: "persistNativeURLIfSupported(url, on: ekReminder)")?.lowerBound
      )
      XCTAssertLessThan(updateManaged, updatePrimarySave)
      XCTAssertLessThan(updatePrimarySave, updateNativeSave)
      let updateBeforePrimarySave = String(update[..<updatePrimarySave])
      XCTAssertFalse(updateBeforePrimarySave.contains("ekReminder.url ="))
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

    func testManagedURLDoesNotRequireAdvancedProcessing() {
      XCTAssertFalse(
        ReminderService.needsAdvancedProcessing(
          tags: nil, parentTitle: nil, flagged: nil, url: "https://example.com/managed"
        )
      )
      XCTAssertTrue(
        ReminderService.needsAdvancedProcessing(
          tags: "test", parentTitle: nil, flagged: nil, url: nil
        )
      )
      XCTAssertTrue(
        ReminderService.needsAdvancedProcessing(
          tags: nil, parentTitle: "parent", flagged: nil, url: nil
        )
      )
      XCTAssertTrue(
        ReminderService.needsAdvancedProcessing(
          tags: nil, parentTitle: nil, flagged: false, url: nil
        )
      )
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
