#if canImport(EventKit)

  import EventKit
  import EventModels
  import Foundation

  // MARK: - Reminder Service

  actor ReminderService {
    private let eventStore = EKEventStore()
    private let permissionService = PermissionService()

    /// Fetch reminders with optional filters
    func fetchReminders(
      listName: String? = nil,
      showCompleted: Bool = false,
      startDate: String? = nil,
      endDate: String? = nil
    ) async throws -> [Reminder] {
      try await permissionService.ensureRemindersAccess()

      let calendars: [EKCalendar]
      if let listName = listName {
        calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
        if calendars.isEmpty {
          throw EventCLIError.notFound("List '\(listName)' not found")
        }
      } else {
        calendars = eventStore.calendars(for: .reminder)
      }

      // Parse the window bounds once before the fetch so a large store isn't
      // re-parsing two constant strings per item, and so an unparseable bound
      // throws (rather than silently returning the whole store) — but outside
      // the non-throwing EventKit completion closure.
      let parsedWindow = try DateValidator.validatedDateWindow(
        startDate: startDate,
        endDate: endDate
      )

      let predicate = eventStore.predicateForReminders(in: calendars)

      return try await withCheckedThrowingContinuation { continuation in
        eventStore.fetchReminders(matching: predicate) { ekReminders in
          guard let ekReminders = ekReminders else {
            continuation.resume(throwing: EventCLIError.eventKitError("Failed to fetch reminders"))
            return
          }

          var reminders = ekReminders.map { Reminder(from: $0) }

          // Filter by completion status
          if !showCompleted {
            reminders = reminders.filter { !$0.isCompleted }
          }

          // Filter by due-date window (startDate inclusive, endDate exclusive).
          if let parsedWindow {
            reminders = reminders.filter {
              DateValidator.isWithinDateWindow($0.dueDate, start: parsedWindow.start, end: parsedWindow.end)
            }
          }

          continuation.resume(returning: reminders)
        }
      }
    }

    /// Create a new reminder
    func createReminder(
      title: String,
      listName: String? = nil,
      notes: String? = nil,
      url: String? = nil,
      dueDate: String? = nil,
      priority: Int? = nil,
      tags: String? = nil,
      parentTitle: String? = nil,
      flagged: Bool? = nil,
      locationTrigger: LocationTrigger? = nil,
      useShortcuts: Bool = true
    ) async throws -> Reminder {
      try await permissionService.ensureRemindersAccess()

      // Step 1: Create basic reminder via EventKit
      let reminderId = try createViaEventKit(
        title: title,
        listName: listName,
        notes: notes,
        url: url,
        dueDate: dueDate,
        priority: priority,
        locationTrigger: locationTrigger
      )

      // Step 2: Post-process with advanced features if needed (tags, flagged, parentTitle, url)
      if needsAdvancedProcessing(tags: tags, parentTitle: parentTitle, flagged: flagged, url: url) {
        try await postProcessReminder(
          id: reminderId,
          tags: tags,
          parentTitle: parentTitle,
          flagged: flagged,
          url: url,
          useShortcuts: useShortcuts
        )
      }

      // Step 3: Fetch and return final state
      return try fetchReminder(id: reminderId)
    }

    /// Update an existing reminder
    func updateReminder(
      id: String,
      title: String? = nil,
      listName: String? = nil,
      completed: Bool? = nil,
      notes: String? = nil,
      dueDate: String? = nil,
      clearDue: Bool = false,
      startDate: String? = nil,
      clearStart: Bool = false,
      priority: Int? = nil,
      tags: String? = nil,
      url: String? = nil,
      parentTitle: String? = nil,
      flagged: Bool? = nil,
      locationTrigger: LocationTrigger? = nil,
      clearLocation: Bool = false,
      useShortcuts: Bool = true
    ) async throws -> Reminder {
      try await permissionService.ensureRemindersAccess()

      // Step 1: Update basic properties via EventKit
      let updatedId = try updateViaEventKit(
        id: id,
        title: title,
        listName: listName,
        completed: completed,
        notes: notes,
        dueDate: dueDate,
        clearDue: clearDue,
        startDate: startDate,
        clearStart: clearStart,
        priority: priority,
        url: url,
        locationTrigger: locationTrigger,
        clearLocation: clearLocation
      )

      // Step 2: Post-process with advanced features if needed
      if needsAdvancedProcessing(tags: tags, parentTitle: parentTitle, flagged: flagged, url: url) {
        try await postProcessReminder(
          id: updatedId,
          tags: tags,
          parentTitle: parentTitle,
          flagged: flagged,
          url: url,
          useShortcuts: useShortcuts
        )
      }

      // Step 3: Fetch and return final state
      return try fetchReminder(id: updatedId)
    }

    /// Search reminders by keyword in title and notes
    func searchReminders(
      keyword: String,
      listName: String? = nil,
      showCompleted: Bool = false
    ) async throws -> [Reminder] {
      let reminders = try await fetchReminders(listName: listName, showCompleted: showCompleted)
      let lowercased = keyword.lowercased()
      return reminders.filter { reminder in
        reminder.title.lowercased().contains(lowercased)
          || (reminder.notes?.lowercased().contains(lowercased) ?? false)
      }
    }

    /// Delete a reminder
    func deleteReminder(id: String) async throws {
      try await permissionService.ensureRemindersAccess()

      guard let ekReminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw EventCLIError.notFound("Reminder with ID '\(id)' not found")
      }

      try eventStore.remove(ekReminder, commit: true)
    }

    // MARK: - Helper Functions

    /// Check if advanced processing is needed
    private func needsAdvancedProcessing(
      tags: String?, parentTitle: String?, flagged: Bool?, url: String?
    ) -> Bool {
      return tags != nil || parentTitle != nil || flagged != nil || url != nil
    }

    /// Fetch a reminder by ID
    fileprivate func fetchReminder(id: String) throws -> Reminder {
      guard let ekReminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw EventCLIError.notFound("Reminder with ID '\(id)' not found")
      }
      return Reminder(from: ekReminder)
    }

    /// Post-process reminder with advanced features via Shortcut
    private func postProcessReminder(
      id: String,
      tags: String?,
      parentTitle: String?,
      flagged: Bool?,
      url: String?,
      useShortcuts: Bool
    ) async throws {
      // Get reminder details for shortcut
      guard let ekReminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw EventCLIError.notFound("Reminder with ID '\(id)' not found")
      }

      let title = ekReminder.title ?? ""
      let listName = ekReminder.calendar?.title ?? "Reminders"

      // If shortcuts are disabled, skip entirely
      if !useShortcuts {
        if tags != nil || parentTitle != nil || flagged != nil || url != nil {
          print(
            "Note: Advanced fields (tags, flagged, parentTitle, url) require Shortcut integration.")
          print("Use without --no-shortcuts to enable.")
        }
        // URL is already persisted by the primary EventKit save.
        return
      }

      let shortcutsService = ShortcutsService()
      let shortcutName = "AdvancedReminderEdit"

      // Check if shortcut is installed
      let isShortcutInstalled: Bool
      do {
        isShortcutInstalled = try await shortcutsService.isShortcutInstalled(name: shortcutName)
      } catch {
        print("Note: Could not check for shortcut. Advanced features disabled.")
        // URL is already persisted by the primary EventKit save.
        return
      }

      // Convert flagged to "Yes"/"No" string for shortcut
      let flaggedString: String? = flagged == true ? "Yes" : (flagged == false ? "No" : nil)

      if isShortcutInstalled {
        let payload = AdvancedReminderEditPayload(
          title: title,
          list: listName,
          tags: tags,
          url: url,
          parentTitle: parentTitle,
          isFlagged: flaggedString
        )

        do {
          _ = try await shortcutsService.runShortcut(name: shortcutName, input: payload)
          return
        } catch {
          print("Note: Shortcut execution failed. Advanced features not set.")
          // URL is already persisted by the primary EventKit save.
          return
        }
      }

      // Shortcut not available - show info message
      print("Note: AdvancedReminderEdit shortcut not found.")
      print("Install it at: https://www.icloud.com/shortcuts/b578334075754da9ba6e50b501515808")
      print("Without it, only basic reminder fields (title, notes, dueDate, priority) can be set.")
      // URL is already persisted by the primary EventKit save.
    }

    /// Create reminder via EventKit (basic properties only)
    private func createViaEventKit(
      title: String,
      listName: String?,
      notes: String?,
      url: String?,
      dueDate: String?,
      priority: Int?,
      locationTrigger: LocationTrigger?
    ) throws -> String {
      let ekReminder = EKReminder(eventStore: eventStore)
      ekReminder.title = title

      // Set calendar (list)
      if let listName = listName {
        let calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
        guard let calendar = calendars.first else {
          throw EventCLIError.notFound("List '\(listName)' not found")
        }
        ekReminder.calendar = calendar
      } else {
        ekReminder.calendar = eventStore.defaultCalendarForNewReminders()
      }

      // Set notes (basic notes, no tags/subtasks)
      if let notes = notes, !notes.isEmpty {
        ekReminder.notes = notes
      }

      // Persist the URL in the primary EventKit save. Shortcuts may still
      // post-process it for richer Reminders.app presentation when enabled.
      Self.applyURL(url, to: ekReminder)

      // Set due date
      if let dueDateString = dueDate {
        let date = try Date.validated(dateTimeString: dueDateString)
        let components = DateComponentsBuilder.build(from: date, timeZone: .current)
        ekReminder.dueDateComponents = components
      }

      // Set priority
      if let priority = priority {
        ekReminder.priority = priority
      }

      // Set location-based alarm
      if let trigger = locationTrigger {
        ekReminder.addAlarm(trigger.toEKAlarm())
      }

      try eventStore.save(ekReminder, commit: true)
      return ekReminder.calendarItemIdentifier
    }

    /// Update reminder via EventKit (basic properties only)
    private func updateViaEventKit(
      id: String,
      title: String?,
      listName: String?,
      completed: Bool?,
      notes: String?,
      dueDate: String?,
      clearDue: Bool,
      startDate: String?,
      clearStart: Bool,
      priority: Int?,
      url: String?,
      locationTrigger: LocationTrigger?,
      clearLocation: Bool
    ) throws -> String {
      guard let original = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw EventCLIError.notFound("Reminder with ID '\(id)' not found")
      }

      // Validate and resolve every non-mutating input before committing a move.
      let parsedDueDate = try dueDate.map { dateString in
        DateComponentsBuilder.build(
          from: try Date.validated(dateTimeString: dateString), timeZone: .current)
      }
      let parsedStartDate = try startDate.map { dateString in
        DateComponentsBuilder.build(
          from: try Date.validated(dateTimeString: dateString), timeZone: .current)
      }
      let targetListName = try Self.validatedTargetListName(listName)
      let needsMove = Self.requiresListMove(
        to: targetListName, currentListName: original.calendar?.title
      )
      let targetList: EKCalendar?
      if needsMove {
        guard
          let targetListName,
          let resolved = eventStore.calendars(for: .reminder).first(where: {
            $0.title == targetListName
          })
        else {
          throw EventCLIError.notFound("List '\(targetListName ?? "")' not found")
        }
        targetList = resolved
      } else {
        targetList = nil
      }

      let movedReminder = try targetList.map { try moveReminderAcrossLists(original, to: $0) }
      let ekReminder = movedReminder ?? original

      if let title = title {
        ekReminder.title = title
      }

      if let completed = completed {
        ekReminder.isCompleted = completed
      }

      if let notes = notes {
        ekReminder.notes = notes
      }

      // Persist the URL in the primary EventKit save. Shortcuts may still
      // post-process it for richer Reminders.app presentation when enabled.
      Self.applyURL(url, to: ekReminder)

      if clearDue {
        ekReminder.dueDateComponents = nil
      } else if let parsedDueDate {
        ekReminder.dueDateComponents = parsedDueDate
      }

      if clearStart {
        ekReminder.startDateComponents = nil
      } else if let parsedStartDate {
        ekReminder.startDateComponents = parsedStartDate
      }

      if let priority = priority {
        ekReminder.priority = priority
      }

      // Location-based alarms: clear or replace. Either operation only touches the
      // location-based alarms; existing time-based alarms are preserved.
      if clearLocation || locationTrigger != nil {
        ekReminder.removeLocationAlarms()
      }
      if let trigger = locationTrigger {
        ekReminder.addAlarm(trigger.toEKAlarm())
      }

      let hasFieldEdits =
        title != nil || completed != nil || notes != nil || dueDate != nil
        || clearDue || startDate != nil || clearStart || priority != nil
        || url != nil || locationTrigger != nil || clearLocation
      if hasFieldEdits {
        do {
          try eventStore.save(ekReminder, commit: true)
        } catch {
          if needsMove {
            throw EventCLIError.eventKitError(
              "Cross-list move to '\(targetListName!)' succeeded but applying field updates failed: \(error.localizedDescription). The reminder is now in the target list with its pre-update field values."
            )
          }
          throw error
        }
      }
      return ekReminder.calendarItemIdentifier
    }

    static func validatedTargetListName(_ listName: String?) throws -> String? {
      guard let listName else { return nil }
      let trimmed = listName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw EventCLIError.invalidInput("Reminder list name cannot be empty.")
      }
      return trimmed
    }

    static func applyURL(_ url: String?, to reminder: EKReminder) {
      guard let url, let validURL = URL(string: url) else { return }
      reminder.url = validURL
    }

    static func requiresListMove(to targetListName: String?, currentListName: String?) -> Bool {
      targetListName.map { $0 != currentListName } ?? false
    }

    private func moveReminderAcrossLists(
      _ reminder: EKReminder, to targetList: EKCalendar
    ) throws -> EKReminder {
      let originalTitle = reminder.title ?? ""
      let originalCreationDate = reminder.creationDate
      let originalIdentifier = reminder.calendarItemIdentifier
      let targetListIdentifier = targetList.calendarIdentifier
      let targetListTitle = targetList.title
      reminder.calendar = targetList

      do {
        try eventStore.save(reminder, commit: true)
        return reminder
      } catch {
        // Discard the rejected in-memory assignment before invoking Reminders.app
        // or inspecting EventKit again.
        eventStore.reset()
        try runAppleScriptMove(
          reminderIdentifier: originalIdentifier,
          toListNamed: targetListTitle
        )
        eventStore.reset()
        eventStore.refreshSourcesIfNecessary()

        guard
          let freshTargetList = eventStore.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == targetListIdentifier
          })
        else {
          throw EventCLIError.eventKitError(
            "Cross-list move completed via Reminders.app but target list '\(targetListTitle)' could not be refreshed. The underlying EventKit error was: \(error.localizedDescription)"
          )
        }
        if let moved = findReminder(
          in: freshTargetList,
          originalIdentifier: originalIdentifier,
          matchingTitle: originalTitle,
          creationDate: originalCreationDate
        ) {
          return moved
        }
        throw EventCLIError.eventKitError(
          "Cross-list move completed via Reminders.app but the moved reminder could not be reliably re-identified in '\(targetListTitle)'; no further field edits were applied. The underlying EventKit error was: \(error.localizedDescription)"
        )
      }
    }

    private func runAppleScriptMove(
      reminderIdentifier: String, toListNamed targetListName: String
    ) throws {
      let escapedList = Self.escapeAppleScriptString(targetListName)
      let script = """
        tell application "Reminders"
          set src to first reminder whose id contains "\(reminderIdentifier)"
          move src to list "\(escapedList)"
        end tell
        """
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      let errorPipe = Pipe()
      process.standardError = errorPipe
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()

      guard process.terminationStatus != 0 else { return }
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let message =
        String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
      if process.terminationStatus == -1743 || message.contains("-1743") {
        throw EventCLIError.eventKitError(
          "Reminders.app move to '\(targetListName)' was blocked by macOS Automation privacy. Grant this app access under System Settings → Privacy & Security → Automation → Reminders, then retry."
        )
      }
      throw EventCLIError.eventKitError("Reminders.app move failed: \(message)")
    }

    static func escapeAppleScriptString(_ value: String) -> String {
      value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func findReminder(
      in list: EKCalendar,
      originalIdentifier: String,
      matchingTitle title: String,
      creationDate: Date?
    ) -> EKReminder? {
      let predicate = eventStore.predicateForReminders(in: [list])
      var found: EKReminder?
      let semaphore = DispatchSemaphore(value: 0)
      eventStore.fetchReminders(matching: predicate) { reminders in
        defer { semaphore.signal() }
        guard let reminders else { return }
        if let exact = reminders.first(where: {
          $0.calendarItemIdentifier == originalIdentifier
        }) {
          found = exact
          return
        }
        let matches = reminders.filter {
          Self.matchesMovedReminder(
            candidateIdentifier: $0.calendarItemIdentifier,
            candidateTitle: $0.title ?? "",
            candidateCreationDate: $0.creationDate,
            originalIdentifier: originalIdentifier,
            originalTitle: title,
            originalCreationDate: creationDate
          )
        }
        if matches.count == 1 {
          found = matches[0]
        }
      }
      semaphore.wait()
      return found
    }

    static func matchesMovedReminder(
      candidateIdentifier: String,
      candidateTitle: String,
      candidateCreationDate: Date?,
      originalIdentifier: String,
      originalTitle: String,
      originalCreationDate: Date?
    ) -> Bool {
      if candidateIdentifier == originalIdentifier { return true }
      guard let candidateCreationDate, let originalCreationDate else { return false }
      return candidateTitle == originalTitle
        && abs(candidateCreationDate.timeIntervalSince(originalCreationDate)) < 1.0
    }
  }

  // MARK: - RemindersBackend Conformance

  extension ReminderService: RemindersBackend {
    func fetchReminder(byId id: String) async throws -> Reminder {
      try fetchReminder(id: id)
    }

    func createReminder(_ params: CreateReminderParams) async throws -> Reminder {
      try await createReminder(
        title: params.title,
        listName: params.listName,
        notes: params.notes,
        url: params.url,
        dueDate: params.dueDate,
        priority: params.priority
      )
    }

    func updateReminder(id: String, params: UpdateReminderParams) async throws -> Reminder {
      try await updateReminder(
        id: id,
        title: params.title,
        listName: nil,
        completed: params.completed,
        notes: params.notes,
        dueDate: params.dueDate,
        clearDue: params.clearDue,
        startDate: params.startDate,
        clearStart: params.clearStart,
        priority: params.priority,
        url: params.url
      )
    }
  }

#endif
