// Portable Pocket TTS renderer (SIM-469).
//
// This is the half of the old pocket_jni.cpp that was never Android-specific:
// it loads the model and renders speech, handing out ~80 ms frames as they are
// produced. Playback is deliberately NOT here — each platform already owns a
// streaming player inside its echo-cancelled audio session (SIM-466), and the
// thin JNI / Obj-C++ bindings feed these frames straight into it.
//
// Frame granularity is what makes local speech feel fast: the model emits audio
// while it is still generating, so playback starts long before the utterance is
// finished. Do not batch frames here.

#ifndef RECEPTIONIST_POCKET_CORE_H_
#define RECEPTIONIST_POCKET_CORE_H_

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace speech_core {
class OnnxPocketTts;
}

namespace pocket {

/// Thrown out of render() when cancel() wins a race with generation.
struct PocketCancelled {};

/// Receives one rendered frame (mono float samples in [-1, 1] at 24 kHz).
/// Called on the render thread; must not block for long.
using PocketFrameSink = std::function<void(const float* samples, int count)>;

class PocketEngine {
 public:
  /// Sample rate every Pocket bundle renders at.
  static constexpr int kSampleRate = 24000;
  /// Largest frame the runtime may emit — 80 ms at 24 kHz.
  static constexpr int kMaxFrameSamples = 1920;

  /// Loads the model from a provisioned bundle directory. Throws on failure.
  explicit PocketEngine(const std::string& directory);
  ~PocketEngine();

  PocketEngine(const PocketEngine&) = delete;
  PocketEngine& operator=(const PocketEngine&) = delete;

  /// Renders `text` in `voice`, delivering frames to `sink` as they are
  /// produced. Throws PocketCancelled if cancelled, std::runtime_error on
  /// failure (including a context exhausted before end-of-speech).
  void render(const std::string& text, const std::string& voice,
              const PocketFrameSink& sink);

  /// Loads each voice's adapter so the first utterance in that voice does not
  /// pay for it. A conversation knows its agents up front, so this runs at
  /// prepare time when nobody is waiting on speech.
  ///
  /// Best effort: a voice that fails to load is skipped, because a warm-up must
  /// never stop a conversation from starting. Returns how many loaded.
  int warmVoices(const std::vector<std::string>& voices);

  /// Asks an in-flight render to stop. Safe to call from another thread.
  void cancel();

  /// Clears the cancelled flag so the engine can serve the next request.
  void reset();

  /// Throws PocketCancelled if a cancel is pending.
  void throwIfCancelled() const;

 private:
  std::unique_ptr<speech_core::OnnxPocketTts> model_;
  std::atomic<bool> cancelled_{false};
};

}  // namespace pocket

#endif  // RECEPTIONIST_POCKET_CORE_H_
