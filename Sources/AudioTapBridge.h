#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

// AVAudioNode reports some device/format races as Objective-C exceptions,
// which Swift's do/catch cannot catch. Return an ordinary error instead.
FOUNDATION_EXPORT NSError * _Nullable MurmurInstallAudioTap(
    AVAudioNode * _Nonnull node, AVAudioNodeBus bus, AVAudioFrameCount size,
    AVAudioFormat * _Nonnull format, AVAudioNodeTapBlock _Nonnull block);
