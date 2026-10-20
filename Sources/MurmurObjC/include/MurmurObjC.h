#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil. Swift can't catch these: AVAudioEngine
/// raises one when a microphone's format doesn't match (installTap), which would otherwise quit the app.
NSException *_Nullable MurmurCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
