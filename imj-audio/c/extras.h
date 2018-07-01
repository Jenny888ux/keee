/*
  This C++ layer on top of the audio-engine defines the
  notion of instruments and uses locks to protect concurrent accesses to
  instruments containers. These locks are acquired
  according to the same global order, everywhere in the code, so as to
  ensure that no deadlock will ever occur.

  These locks are not taken by the audio realtime thread,
  which remains lock-free unless IMJ_AUDIO_MASTERGLOBALLOCK is used.
*/

#include "compiler.prepro.h"
#include "cpp.audio/include/public.h"

#ifdef __cplusplus

namespace imajuscule {
  namespace audioelement {

    using AudioFloat = float;

    template <typename Envel>
    using VolumeAdjustedOscillator =
      FinalAudioElement<
        Enveloped<
          VolumeAdjusted<
            OscillatorAlgo<
              typename Envel::FPT
            , eNormalizePolicy::FAST
            >
          >
        , Envel
        >
      >;

    template<typename S>
    struct SetParam;
    template<typename S>
    struct HasNoteOff;

    template<Atomicity A, typename T, EnvelopeRelease Rel>
    struct SetParam<AHDSREnvelope<A, T, Rel>> {
      template<typename B>
      static void set(AHDSR const & env, B & b) {
        b.forEachElems([&env](auto & e) { e.algo.editEnveloppe().setAHDSR(env); });
      }
    };

    template<Atomicity A, typename T, EnvelopeRelease Rel>
    struct HasNoteOff<AHDSREnvelope<A, T, Rel>> {
      static constexpr bool value = Rel == EnvelopeRelease::WaitForKeyRelease;
    };

    template<typename Env>
    std::pair<std::vector<float>, int> envelopeGraphVec(typename Env::Param const & envParams) {
      Env e;
      e.setAHDSR(envParams);
      // emulate a key-press
      e.onKeyPressed();
      int splitAt = -1;

      std::vector<float> v, v2;
      v.reserve(10000);
      for(int i=0; e.getRelaxedState() != EnvelopeState::EnvelopeDone1; ++i) {
        e.step();
        v.push_back(static_cast<float>(e.value()));
        if(!e.afterAttackBeforeSustain()) {
          splitAt = v.size();
          if constexpr (Env::Release == EnvelopeRelease::WaitForKeyRelease) {
            // emulate a key-release
            e.onKeyReleased();
          }
          break;
        }
      }
      while(e.getRelaxedState() != EnvelopeState::EnvelopeDone1) {
        e.step();
        v.push_back(e.value());
      }
      return {std::move(v),splitAt};
    }
  }

  namespace audio {

#ifdef IMJ_AUDIO_MASTERGLOBALLOCK
#pragma message "IMJ_AUDIO_MASTERGLOBALLOCK mode is not recommended, it will lead to audio glitches under contention."
    static constexpr auto audioEnginePolicy = AudioOutPolicy::MasterGlobalLock;
#else
    // This lockfree mode is recommended, it reduces the likelyhood of audio glitches.
    static constexpr auto audioEnginePolicy = AudioOutPolicy::MasterLockFree;
#endif

    using AllChans = ChannelsVecAggregate< 2, audioEnginePolicy >;

    using NoXFadeChans = typename AllChans::NoXFadeChans;
    using XFadeChans = typename AllChans::XFadeChans;

    using ChannelHandler = outputDataBase< AllChans >;

    using Ctxt = AudioOutContext<
      ChannelHandler,
      Features::JustOut,
      AudioPlatform::PortAudio
      >;

    Ctxt & getAudioContext();

    XFadeChans *& getXfadeChannels();

    Event mkNoteOn(int pitch, float velocity);

    Event mkNoteOff(int pitch);

    namespace sine {
      template <typename Env>
      using SynthT = Synth <
        Ctxt::policy
      , Ctxt::nAudioOut
      , XfadePolicy::SkipXfade
      , audioelement::Oscillator<Env>
      , audioelement::HasNoteOff<Env>::value
      , EventIterator<IEventList>
      , NoteOnEvent
      , NoteOffEvent>;
    }

    namespace vasine {
      template <typename Env>
      using SynthT = Synth <
        Ctxt::policy
      , Ctxt::nAudioOut
      , XfadePolicy::SkipXfade
      , audioelement::VolumeAdjustedOscillator<Env>
      , audioelement::HasNoteOff<Env>::value
      , EventIterator<IEventList>
      , NoteOnEvent
      , NoteOffEvent>;
    }
    namespace mySynth = imajuscule::audio::vasine;
    //namespace mySynth = imajuscule::audio::sine;

    template<typename T>
    struct withChannels {
      withChannels(NoXFadeChans & chans) : chans(chans), obj(buffers) {}
      ~withChannels() {
        std::lock_guard<std::mutex> l(isUsed); // see 'Using'
      }

      template<typename Out>
      auto onEvent2(Event e, Out & out) {
        return obj.onEvent2(e, out, chans);
      }

      void finalize() {
        obj.finalize();
      }

      T obj;
      NoXFadeChans & chans;
      std::mutex isUsed;

      static constexpr auto n_mnc = T::n_channels;
      using mnc_buffer = typename T::MonoNoteChannel::buffer_t;
      std::array<mnc_buffer,n_mnc> buffers;
    };

    // a 'Using' instance gives the guarantee that the object 'o' passed to its constructor
    // won't be destroyed during the entire lifetime of the instance, iff the following conditions hold:
    //   (1) 'protectsDestruction' passed to the constructor is currently locked
    //   (2) T::~T() locks, then unlocks 'o.isUsed', so that 'o' cannot be destroyed
    //         until 'protectsDestruction' is unlocked
    template<typename T>
    struct Using {
      T & o; // this reference makes the object move-only, which is what we want

      Using(std::lock_guard<std::mutex> && protectsDestruction, T&o) : o(o) {
        o.isUsed.lock();
        // NOTE here, both the instrument lock (isUsed) and the 'protectsDestruction' lock
        // are taken.
        //
        // The order in which we take the locks is important to avoid deadlocks:
        // it is OK to take multiple locks at the same time, /only/ if, everywhere in the program,
        // we take them respecting a global order on the locks of the program.
        //
        // Hence, here the global order is:
        // map lock (protectsDestruction) -> instrument lock (isUsed)
      }
      ~Using() {
        o.isUsed.unlock();
      }
    };

    struct tryScopedLock {
      tryScopedLock(std::mutex&m) : m(m) {
        success = m.try_lock();
      }
      operator bool () const {
        return success;
      }
      ~tryScopedLock() {
        if(success) {
          m.unlock();
        }
      }
    private:
      std::mutex & m;
      bool success;
    };

    template <typename Envel>
    struct Synths {
      using T = mySynth::SynthT<Envel>;
      using K = typename Envel::Param;

      // NOTE the 'Using' is constructed while we hold the lock to the map.
      // Hence, while garbage collecting / recycling, if we take the map lock,
      // and if the instrument lock is not taken, we have the guarantee that
      // the instrument lock won't be taken until we release the map lock.
      static Using<withChannels<T>> get(K const & envelParam) {
        using namespace audioelement;
        // we use a global lock because we can concurrently modify and lookup the map.
        std::lock_guard<std::mutex> l(map_mutex());

        auto & synths = map();

        auto it = synths.find(envelParam);
        if(it != synths.end()) {
          return Using(std::move(l), *(it->second));
        }
        if(auto * p = recycleInstrument(synths, envelParam)) {
          return Using(std::move(l), *p);
        }
        auto [c,remover] = addNoXfadeChannels(T::n_channels);
        auto p = std::make_unique<withChannels<T>>(c);
        SetParam<Envel>::set(envelParam, p->obj);
        if(!p->obj.initialize(p->chans)) {
          auto oneSynth = synths.begin();
          if(oneSynth != synths.end()) {
            LG(ERR, "a preexisting synth is returned");
            // The channels have the same lifecycle as the instrument, the instrument will be destroyed
            //  so we remove the associated channels:
            remover.flagForRemoval();
            return Using(std::move(l), *(oneSynth->second.get()));
          }
          LG(ERR, "an uninitialized synth is returned");
        }
        return Using(
            std::move(l)
          , *(synths.emplace(envelParam, std::move(p)).first->second));
      }

      static void finalize() {
        std::lock_guard<std::mutex> l(map_mutex());
        for(auto & s : map()) {
          s.second->finalize();
        }
        map().clear();
      }

    private:
      using Map = std::map<K,std::unique_ptr<withChannels<T>>>;

      static auto & map() {
        static Map m;
        return m;
      }
      static auto & map_mutex() {
        static std::mutex m;
        return m;
      }

      /* The caller is expected to take the map mutex. */
      static withChannels<T> * recycleInstrument(Map & synths, K const & envelParam) {
        for(auto it = synths.begin(), end = synths.end(); it != end; ++it) {
          auto & i = it->second;
          if(!i) {
            LG(ERR,"inconsistent map");
            continue;
          }
          auto & o = *i;
          if(auto scoped = tryScopedLock(o.isUsed)) {
            // we don't take the audio lock because 'hasRealtimeFunctions' relies on an
            // atomically incremented / decremented counter.
            if(o.chans.hasRealtimeFunctions()) {
              continue;
            }

            // We can assume that all enveloppes are finished : should one
            // not be finished, it would not have a chance to ever finish
            // because there is 0 real-time std::function (oneShots/orchestrator/compute),
            // and no note is being started, because the map mutex has been taken.
            Assert(o.obj.areEnvelopesFinished() && "inconsistent envelopes");

            /*
            auto node = synths.extract(it);
            node.key() = envelParam;
            auto [inserted, isNew] = synths.insert(std::move(node));
            */
            // the code above uses C++17 features not present in clang yet, it is
            // replaced by the code below.
            std::unique_ptr<withChannels<T>> new_p;
            new_p.swap(it->second);
            synths.erase(it);
            auto [inserted, isNew] = synths.emplace(envelParam, std::move(new_p));

            Assert(isNew); // because prior to calling this function, we did a lookup
            using namespace audioelement;
            SetParam<Envel>::set(envelParam, inserted->second->obj);
            return inserted->second.get();
          }
          else {
            // a note is being started or stopped, we can't recycle this instrument.
          }
        }
        return nullptr;
      }

      static auto addNoXfadeChannels(int nVoices) {
        static constexpr auto n_max_orchestrator_per_channel = 0; // we don't use orchestrators
        return getAudioContext().getChannelHandler().getChannels().getChannelsNoXFade().emplace_front(
          getAudioContext().getChannelHandler().get_lock_policy(),
          std::min(nVoices, static_cast<int>(std::numeric_limits<uint8_t>::max())),
          n_max_orchestrator_per_channel);
      }
    };

    template<typename Env>
    onEventResult midiEvent(typename Env::Param const & env, Event e) {
      return Synths<Env>::get(env).o.onEvent2(e, getAudioContext().getChannelHandler());
    }

    using VoiceWindImpl = Voice<Ctxt::policy, Ctxt::nAudioOut, audio::SoundEngineMode::WIND, true>;

    VoiceWindImpl & windVoice();

  } // NS audio
} // NS imajuscule

#endif
