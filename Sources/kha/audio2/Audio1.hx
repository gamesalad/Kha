package kha.audio2;

#if cpp
import sys.thread.Mutex;
#end
import haxe.ds.Vector;

class Audio1 {
	static inline var channelCount: Int = 32;
	static var soundChannels: Vector<AudioChannel>;
	static var streamChannels: Vector<StreamChannel>;

	static var internalSoundChannels: Vector<AudioChannel>;
	static var internalStreamChannels: Vector<StreamChannel>;
	static var sampleCache1: kha.arrays.Float32Array;
	static var sampleCache2: kha.arrays.Float32Array;
	static var lastAllocationCount: Int = 0;

	#if cpp
	static var mutex: Mutex;
	#end

	@:noCompletion
	public static function _init(): Void {
		#if cpp
		mutex = new Mutex();
		#end
		soundChannels = new Vector<AudioChannel>(channelCount);
		streamChannels = new Vector<StreamChannel>(channelCount);
		internalSoundChannels = new Vector<AudioChannel>(channelCount);
		internalStreamChannels = new Vector<StreamChannel>(channelCount);
		sampleCache1 = new kha.arrays.Float32Array(512);
		sampleCache2 = new kha.arrays.Float32Array(512);
		lastAllocationCount = 0;
		Audio.audioCallback = mix;
	}

	static inline function max(a: Float, b: Float): Float {
		return a > b ? a : b;
	}

	static inline function min(a: Float, b: Float): Float {
		return a < b ? a : b;
	}

	public static function mix(samplesBox: kha.internal.IntBox, buffer: Buffer): Void {
		var samples = samplesBox.value;
		if (sampleCache1.length < samples) {
			if (Audio.disableGcInteractions) {
				trace("Unexpected allocation request in audio thread.");
				for (i in 0...samples) {
					buffer.data.set(buffer.writeLocation, 0);
					buffer.writeLocation += 1;
					if (buffer.writeLocation >= buffer.size) {
						buffer.writeLocation = 0;
					}
				}
				lastAllocationCount = 0;
				Audio.disableGcInteractions = false;
				return;
			}
			sampleCache1 = new kha.arrays.Float32Array(samples * 2);
			sampleCache2 = new kha.arrays.Float32Array(samples * 2);
			lastAllocationCount = 0;
		}
		else {
			if (lastAllocationCount > 100) {
				Audio.disableGcInteractions = true;
			}
			else {
				lastAllocationCount += 1;
			}
		}

		for (i in 0...samples) {
			sampleCache2[i] = 0;
		}

		#if cpp
		// An exception must not leave the mutex held: the native audio callback swallows it to keep the audio thread alive, and the next acquire on
		// another thread would then wait forever.
		mutex.acquire();
		try {
			copyChannels();
		}
		catch (e: Dynamic) {
			mutex.release();
			throw e;
		}
		mutex.release();
		#else
		copyChannels();
		#end

		for (channel in internalSoundChannels) {
			if (channel == null || channel.finished)
				continue;
			channel.nextSamples(sampleCache1, samples, buffer.samplesPerSecond);
			for (i in 0...samples) {
				sampleCache2[i] += sampleCache1[i] * channel.volume;
			}
		}
		for (channel in internalStreamChannels) {
			if (channel == null || channel.finished)
				continue;
			channel.nextSamples(sampleCache1, samples, buffer.samplesPerSecond);
			for (i in 0...samples) {
				sampleCache2[i] += sampleCache1[i] * channel.volume;
			}
		}

		for (i in 0...samples) {
			buffer.data.set(buffer.writeLocation, max(min(sampleCache2[i], 1.0), -1.0));
			buffer.writeLocation += 1;
			if (buffer.writeLocation >= buffer.size) {
				buffer.writeLocation = 0;
			}
		}
	}

	static function copyChannels(): Void {
		for (i in 0...channelCount) {
			internalSoundChannels[i] = soundChannels[i];
		}
		for (i in 0...channelCount) {
			internalStreamChannels[i] = streamChannels[i];
		}
	}

	public static function play(sound: Sound, loop: Bool = false): kha.audio1.AudioChannel {
		var channel: kha.audio2.AudioChannel = null;
		if (Audio.samplesPerSecond != sound.sampleRate) {
			channel = new ResamplingAudioChannel(loop, sound.sampleRate);
		}
		else {
			#if sys_ios
			channel = new ResamplingAudioChannel(loop, sound.sampleRate);
			#else
			channel = new AudioChannel(loop);
			#end
		}
		channel.data = sound.uncompressedData;
		var foundChannel = false;

		#if cpp
		// Same as in mix: an exception must not leave the mutex held, the audio thread would wait for it forever.
		mutex.acquire();
		try {
			foundChannel = addSoundChannel(channel);
		}
		catch (e: Dynamic) {
			mutex.release();
			throw e;
		}
		mutex.release();
		#else
		foundChannel = addSoundChannel(channel);
		#end

		return foundChannel ? channel : null;
	}

	static function addSoundChannel(channel: kha.audio2.AudioChannel): Bool {
		for (i in 0...channelCount) {
			if (soundChannels[i] == null || soundChannels[i].finished) {
				soundChannels[i] = channel;
				return true;
			}
		}
		return false;
	}

	public static function _playAgain(channel: kha.audio2.AudioChannel): Void {
		#if cpp
		mutex.acquire();
		try {
			readdSoundChannel(channel);
		}
		catch (e: Dynamic) {
			mutex.release();
			throw e;
		}
		mutex.release();
		#else
		readdSoundChannel(channel);
		#end
	}

	static function readdSoundChannel(channel: kha.audio2.AudioChannel): Void {
		for (i in 0...channelCount) {
			if (soundChannels[i] == channel) {
				soundChannels[i] = null;
			}
		}
		for (i in 0...channelCount) {
			if (soundChannels[i] == null || soundChannels[i].finished || soundChannels[i] == channel) {
				soundChannels[i] = channel;
				break;
			}
		}
	}

	public static function stream(sound: Sound, loop: Bool = false): kha.audio1.AudioChannel {
		{
			// try to use hardware accelerated audio decoding
			var hardwareChannel = Audio.stream(sound, loop);
			if (hardwareChannel != null)
				return hardwareChannel;
		}

		var channel: StreamChannel = new StreamChannel(sound.compressedData, loop);
		var foundChannel = false;

		#if cpp
		mutex.acquire();
		try {
			foundChannel = addStreamChannel(channel);
		}
		catch (e: Dynamic) {
			mutex.release();
			throw e;
		}
		mutex.release();
		#else
		foundChannel = addStreamChannel(channel);
		#end

		return foundChannel ? channel : null;
	}

	static function addStreamChannel(channel: StreamChannel): Bool {
		for (i in 0...channelCount) {
			if (streamChannels[i] == null || streamChannels[i].finished) {
				streamChannels[i] = channel;
				return true;
			}
		}
		return false;
	}
}
