#import "AudioTapBridge.h"

NSError *MurmurInstallAudioTap(AVAudioNode *node, AVAudioNodeBus bus,
                              AVAudioFrameCount size, AVAudioFormat *format,
                              AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:bus bufferSize:size format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"app.murmur.audio" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"The microphone couldn’t start. Check the selected microphone and try again."
        }];
    }
}
