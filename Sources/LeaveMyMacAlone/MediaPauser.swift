import Foundation

/// Pauses whatever is playing (Music, Spotify, a browser video, QuickTime…) via
/// the system Now Playing service, so audio and video stop when the Mac locks.
///
/// Sends an explicit *pause* command — unlike the play/pause media key, which
/// toggles and would START playback (e.g. launch Music) when nothing is playing.
/// MediaRemote is a private framework, so it is loaded dynamically: if a future
/// macOS removes or restricts it, this silently becomes a no-op and the lock is
/// unaffected.
enum MediaPauser {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let pauseCommand: UInt32 = 1   // kMRPause

    private static let sendCommand: SendCommand? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static func pauseNowPlaying() {
        _ = sendCommand?(pauseCommand, nil)
    }
}
