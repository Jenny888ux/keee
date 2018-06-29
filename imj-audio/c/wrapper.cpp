#include "compiler.prepro.h"
#include "extras.h"

#ifdef __cplusplus

namespace imajuscule::audio {
  /*
  * Is equal to:
  *   number of calls to 'initializeAudioOutput' - number of calls to 'teardownAudioOutput'
  */
  int & countUsers() {
    static int n(0);
    return n;
  }

  /*
  * Protects access to countUsers() and the initialization / uninitialization of the global audio output stream
  */
  std::mutex & initMutex() {
    static std::mutex m;
    return m;
  }
}



extern "C" {

/*  void testFreeList() {
    using FL = imajuscule::FreeList<int64_t, 4096/sizeof(int64_t)>;
    FL l;
    l.Take();
// should the size of the free list be limited to a page/ aligned to the start of the page?
    using namespace imajuscule::audioelement;
    using namespace imajuscule::audio::mySynth;
    using namespace imajuscule::audio;
    std::cout << "sizeof synth " << sizeof(SynthT<AHDSREnvelope<float, EnvelopeRelease::ReleaseAfterDecay>>) << std::endl;
    std::cout << "sizeof mnc " << sizeof(MonoNoteChannel<VolumeAdjustedOscillator<AHDSREnvelope<float, EnvelopeRelease::ReleaseAfterDecay>>, NoXFadeChans>) << std::endl;
    std::cout << "sizeof au " << sizeof(AEBuffer<float>) << std::endl;
    std::cout << "sizeof aub " << sizeof(AEBuffer<float>::buffer_placeholder_t) << std::endl;
    union {
        AEBuffer<float>::buffer_placeholder_t for_alignment;
        float buffer[n_frames_per_buffer];
    } u;
    std::cout << "sizeof auu " << sizeof(u) << std::endl;

    struct F { // 64 bytes
      union {
          AEBuffer<float>::buffer_placeholder_t for_alignment;
          float buffer[n_frames_per_buffer];
      };
    };
    struct G_ { // 128 bytes
      union {
          AEBuffer<float>::buffer_placeholder_t for_alignment;
          float buffer[n_frames_per_buffer];
      };
      bool me : 1;
    };
    struct G { // 128 bytes
      union {
          AEBuffer<float>::buffer_placeholder_t for_alignment;
          float buffer[n_frames_per_buffer];
      };
      bool me : 1;
    }__attribute__((packed));
    struct G2 { // 128 bytes
      union {
          AEBuffer<float>::buffer_placeholder_t for_alignment;
          float buffer[n_frames_per_buffer];
      };
      bool me;
    }__attribute__((packed));
    struct g2_ : public G2 {
      int32_t i;
    }__attribute__((packed));
    struct g2 : public G2 {
      int32_t i : 3;
    }__attribute__((packed));

    struct H { // 68 bytes
      union {
          float buffer[n_frames_per_buffer];
      };
      bool me : 1;
    };
    struct H2 { // 68 bytes
      float buffer[n_frames_per_buffer];
      bool me : 1;
    };
    struct I { // 128 bytes
      union {
          AEBuffer<float>::buffer_placeholder_t for_alignment;
      };
      bool me : 1;
    };
    struct I2 { // 128 bytes
      AEBuffer<float>::buffer_placeholder_t for_alignment;
      bool me : 1;
    };
    struct i2_ : public I2 {
      int stuff;
    };
    struct i2 : public I2 {
      int stuff;
    }__attribute__((packed));
    struct ii2 : public i2 {
      int stuff2;
    };

    std::cout << "sizeof F " << sizeof(F) << std::endl;
    std::cout << "sizeof G_ " << sizeof(G_) << std::endl;
    std::cout << "sizeof G " << sizeof(G) << std::endl;
    std::cout << "sizeof G2 " << sizeof(G2) << std::endl;
    std::cout << "sizeof g2_ " << sizeof(g2_) << std::endl;
    std::cout << "sizeof g2 " << sizeof(g2) << std::endl;
    std::cout << "sizeof H " << sizeof(H) << std::endl;
    std::cout << "sizeof H2 " << sizeof(H2) << std::endl;
    std::cout << "sizeof I " << sizeof(I) << std::endl;
    std::cout << "sizeof I2 " << sizeof(I2) << std::endl;
    std::cout << "sizeof i2_ " << sizeof(i2_) << std::endl;
    std::cout << "sizeof i2 " << sizeof(i2) << std::endl;
    std::cout << "sizeof ii2 " << sizeof(ii2) << std::endl;

    std::cout << "sizeof NoXFadeChans " << sizeof(NoXFadeChans) << std::endl;
  }*/

  /*
  * Increments the count of users, and
  *
  * - If we are the first user:
  *     initializes the audio output context,
  *     taking into account the latency parameters,
  * - Else:
  *     returns the result of the first initialization,
  *     ignoring the latency parameters.
  *
  * Every successfull or unsuccessfull call to this function
  *   should be matched by a call to 'teardownAudioOutput'.
  *   .
  * @param minLatencySeconds :
  *   The minimum portaudio latency, in seconds.
  *   Pass 0.f to use the smallest latency possible.
  * @param portaudioMinLatencyMillis :
  *   If strictly positive, overrides the portaudio minimum latency by
  *     setting an environment variable.
  *
  * @returns true on success, false on error.
  */
  bool initializeAudioOutput (float minLatencySeconds, int portaudioMinLatencyMillis) {
    using namespace std;
    using namespace imajuscule;
    using namespace imajuscule::audio;

    std::lock_guard l(initMutex());
    ++countUsers();
    LG(INFO, "initializeAudioOutput: nUsers = %d", countUsers());

    {
      if( countUsers() > 1) {
        // We are ** not ** the first user.
        return getAudioContext().Initialized();
      }
      else if(countUsers() <= 0) {
        LG(ERR, "initializeAudioOutput: nUsers = %d", countUsers());
        Assert(0);
        return getAudioContext().Initialized();
      }
    }

#ifndef NDEBUG
    cout << "Warning : C++ sources of imj-audio were built without NDEBUG" << endl;
#endif

#ifdef IMJ_AUDIO_MASTERGLOBALLOCK
    cout << "Warning : C++ sources of imj-audio were built with IMJ_AUDIO_MASTERGLOBALLOCK. " <<
    "This may lead to audio glitches under contention." << endl;
#endif

    if(portaudioMinLatencyMillis > 0) {
      if(!overridePortaudioMinLatencyMillis(portaudioMinLatencyMillis)) {
        return false;
      }
    }

    disableDenormals();

    //testFreeList();

    // add a single Xfade channel (for 'SoundEngine' and 'Channel' that don't support envelopes entirely)
    static constexpr auto n_max_orchestrator_per_channel = 1;
    auto [xfadeChan, _] = getAudioContext().getChannelHandler().getChannels().getChannelsXFade().emplace_front(
      getAudioContext().getChannelHandler().get_lock_policy(),
      std::numeric_limits<uint8_t>::max(),
      n_max_orchestrator_per_channel);

    windVoice().initializeSlow();
    if(!windVoice().initialize(xfadeChan)) {
      LG(ERR,"windVoice().initialize failed");
      return false;
    }
    getXfadeChannels() = &xfadeChan;

    if(!getAudioContext().Init(minLatencySeconds)) {
      return false;
    }
    // On macOS 10.13.5, this delay is necessary to be able to play sound,
    //   it might be a bug in portaudio where Pa_StartStream doesn't wait for the
    //   stream to be up and running.
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    return true;
  }

  /*
  * Decrements the count of users, and if we are the last user,
  *   shutdowns audio output after having driven the audio signal to 0.
  *
  * Every successfull or unsuccessfull call to 'initializeAudioOutput'
  * must be matched by a call to this function.
  */
  void teardownAudioOutput() {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;

    std::lock_guard l(initMutex());

    --countUsers();
    LG(INFO, "teardownAudioOutput  : nUsers = %d", countUsers());
    if(countUsers() > 0) {
      // We are ** not ** the last user.
      return;
    }

    if(getAudioContext().Initialized()) {
      // This will "quickly" crossfade the audio output channels to zero.
      getAudioContext().onApplicationShouldClose();

      // we sleep whil channels are crossfaded to zero

      int bufferSize = n_audio_cb_frames.load(std::memory_order_relaxed);
      if(bufferSize == initial_n_audio_cb_frames) {
        // assume a very big buffer size if the audio callback didn't have a chance
        // to run yet.
        bufferSize = 10000;
      }
      float latencyTime = bufferSize / static_cast<float>(SAMPLE_RATE);
      float fadeOutTime = xfade_on_close / static_cast<float>(SAMPLE_RATE);
      float marginTimeSeconds = 0.020f; // taking into account the time to run the code
      float waitSeconds = 2*latencyTime + 2*fadeOutTime + marginTimeSeconds;
      std::this_thread::sleep_for( std::chrono::milliseconds(1 + static_cast<int>(waitSeconds * 1000)));
    }

    // All channels have crossfaded to 0 by now.

    windVoice().finalize();

    static constexpr auto A = getAtomicity<audio::Ctxt::policy>();

    Synths<SimpleLinearEnvelope<A, AudioFloat>>::finalize();
    Synths<AHDSREnvelope<A, AudioFloat, EnvelopeRelease::WaitForKeyRelease>>::finalize();
    Synths<AHDSREnvelope<A, AudioFloat, EnvelopeRelease::ReleaseAfterDecay>>::finalize();

    getAudioContext().TearDown();

    getAudioContext().getChannelHandler().getChannels().getChannelsXFade().clear();
    getAudioContext().getChannelHandler().getChannels().getChannelsNoXFade().clear();
  }

  bool midiNoteOn(int envelCharacTime, int16_t pitch, float velocity) {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;
    static constexpr auto A = getAtomicity<Ctxt::policy>();
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    return convert(midiEvent<SimpleLinearEnvelope<A, AudioFloat>>(envelCharacTime, mkNoteOn(pitch,velocity)));
  }
  bool midiNoteOff(int envelCharacTime, int16_t pitch) {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;
    static constexpr auto A = getAtomicity<Ctxt::policy>();
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    return convert(midiEvent<SimpleLinearEnvelope<A, AudioFloat>>(envelCharacTime, mkNoteOff(pitch)));
  }

  bool midiNoteOnAHDSR_(imajuscule::envelType t, int a, int ai, int h, int d, int di, float s, int r, int ri, int16_t pitch, float velocity) {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    auto p = AHDSR{a,itp::toItp(ai),h,d,itp::toItp(di),r,itp::toItp(ri),s};
    auto n = mkNoteOn(pitch,velocity);
    return convert(midiEventAHDSR(t, p, n));
  }
  bool midiNoteOffAHDSR_(imajuscule::envelType t, int a, int ai, int h, int d, int di, float s, int r, int ri, int16_t pitch) {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    auto p = AHDSR{a,itp::toItp(ai),h,d,itp::toItp(di),r,itp::toItp(ri),s};
    auto n = mkNoteOff(pitch);
    return convert(midiEventAHDSR(t, p, n));
  }

  float* analyzeAHDSREnvelope_(imajuscule::envelType t, int a, int ai, int h, int d, int di, float s, int r, int ri, int*nElems, int*splitAt) {
    using namespace imajuscule;
    using namespace imajuscule::audio;
    using namespace imajuscule::audioelement;
    auto p = AHDSR{a,itp::toItp(ai),h,d,itp::toItp(di),r,itp::toItp(ri),s};
    return analyzeEnvelopeGraph(t, p, nElems, splitAt);
  }

  bool effectOn(int program, int16_t pitch, float velocity) {
    using namespace imajuscule::audio;
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    auto voicing = Voicing(program,pitch,velocity,0.f,true,0);
    return convert(playOneThing(windVoice(),getAudioContext().getChannelHandler(),*getXfadeChannels(),voicing));
  }

  bool effectOff(int16_t pitch) {
    using namespace imajuscule::audio;
    if(unlikely(!getAudioContext().Initialized())) {
      return false;
    }
    return convert(stopPlaying(windVoice(),getAudioContext().getChannelHandler(),*getXfadeChannels(),pitch));
  }
}

#endif
