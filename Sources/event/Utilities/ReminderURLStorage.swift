import Foundation

enum ReminderURLStorage {
  struct ExposedValues {
    let notes: String?
    let url: String?
  }

  private static let markerPrefix = "event URL (managed; base64): "

  static func storing(_ url: String, in notes: String?) -> String {
    let userNotes = exposedValues(notes: notes, nativeURL: nil).notes
    let encoded = Data(url.utf8).base64EncodedString()
    let marker = markerPrefix + encoded
    guard let userNotes, !userNotes.isEmpty else { return marker }
    return userNotes + "\n\n" + marker
  }

  static func exposedValues(notes: String?, nativeURL: URL?) -> ExposedValues {
    let split = splitManagedURL(from: notes)
    return ExposedValues(notes: split.notes, url: split.url ?? nativeURL?.absoluteString)
  }

  private static func splitManagedURL(from notes: String?) -> ExposedValues {
    guard let notes,
      let markerRange = notes.range(of: markerPrefix, options: .backwards),
      markerRange.lowerBound == notes.startIndex
        || notes[..<markerRange.lowerBound].hasSuffix("\n\n")
    else {
      return ExposedValues(notes: notes, url: nil)
    }

    let encoded = String(notes[markerRange.upperBound...])
    guard !encoded.isEmpty,
      !encoded.contains(where: { $0.isWhitespace }),
      let data = Data(base64Encoded: encoded),
      let url = String(data: data, encoding: .utf8),
      URL(string: url) != nil
    else {
      return ExposedValues(notes: notes, url: nil)
    }

    if markerRange.lowerBound == notes.startIndex {
      return ExposedValues(notes: nil, url: url)
    }
    let separatorStart = notes.index(markerRange.lowerBound, offsetBy: -2)
    let userNotes = String(notes[..<separatorStart])
    return ExposedValues(notes: userNotes.isEmpty ? nil : userNotes, url: url)
  }
}
