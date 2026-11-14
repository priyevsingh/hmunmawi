import Foundation
import HmunmawiCore

extension URL {
    /// ~/Library/Application Support/Hmunmawi (or the test profile's own folder): where every data file of the app lives.
    static var hmSupport: URL { URL.applicationSupportDirectory.appending(path: TestProfile.supportFolderName, directoryHint: .isDirectory) }
}
