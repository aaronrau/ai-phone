#include "pocket_core.h"

#include "speech_core/models/onnx_pocket_tts.h"

#include <cmath>
#include <cstdlib>
#include <stdexcept>
#include <string>

#if defined(__ANDROID__)
#include <android/log.h>
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>
#include <algorithm>
#include <climits>
#include <fstream>
#endif

namespace pocket {
namespace {

void check(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}

#if defined(__ANDROID__)
// Only the dedicated inference worker is pinned. Never assume CPU numbers: use
// allowed CPUs with the highest reported maximum frequency, if heterogeneous.
// Android exposes cpufreq; on iOS the scheduler handles big/little itself and
// there is no equivalent (or permitted) affinity control.
void preferFastCores() {
  cpu_set_t allowed, fastest;
  CPU_ZERO(&allowed);
  CPU_ZERO(&fastest);
  if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) return;
  long highest = 0, lowest = LONG_MAX;
  for (int i = 0; i < CPU_SETSIZE; ++i) {
    if (!CPU_ISSET(i, &allowed)) continue;
    std::ifstream file("/sys/devices/system/cpu/cpu" + std::to_string(i) +
                       "/cpufreq/cpuinfo_max_freq");
    long frequency = 0;
    if (!(file >> frequency) || frequency <= 0) return;  // Let Android schedule.
    lowest = std::min(lowest, frequency);
    if (frequency > highest) {
      highest = frequency;
      CPU_ZERO(&fastest);
    }
    if (frequency == highest) CPU_SET(i, &fastest);
  }
  if (highest > lowest && CPU_COUNT(&fastest) >= 2)
    sched_setaffinity(0, sizeof(fastest), &fastest);
}

// Flutter pins its raster thread to the same performance cores and runs it
// (and the UI thread) at negative nice, so at default priority the two Pocket
// threads were preempted to ~0.67x real time during a conversation while the
// isolated bench on the same device holds ~1.0x (SIM-477). These threads are
// the only real-time audio producer in the process: run them at Android's
// THREAD_PRIORITY_AUDIO (-16), which apps may set for their own threads. The
// pipeline's producer thread is spawned from here and inherits the nice value
// and affinity.
constexpr int kAudioThreadPriority = -16;

void preferAudioPriority() {
  const pid_t tid = gettid();
  const int result = setpriority(PRIO_PROCESS, tid, kAudioThreadPriority);
  __android_log_print(ANDROID_LOG_DEBUG, "PocketTts",
                      "render thread tid=%d nice=%d (%s)", tid,
                      getpriority(PRIO_PROCESS, tid),
                      result == 0 ? "audio priority" : "default priority");
}
#else
void preferFastCores() {}
void preferAudioPriority() {}
#endif

}  // namespace

PocketEngine::PocketEngine(const std::string& directory) {
  preferFastCores();
  preferAudioPriority();
  // Enables the runtime's two-stage generation/decoding pipeline, which is what
  // lets audio start before the whole utterance has been generated.
  setenv("SIM453_POCKET_PIPELINE", "1", 1);

  speech_core::PocketTtsConfig config;
  config.intra_threads = 1;
  config.flow_steps = 2;
  config.seed = -1;
  model_ = std::make_unique<speech_core::OnnxPocketTts>(directory, config);
  // Cache the default preset prompt; other reference prompts load on demand.
  // Per-voice LM/decoder states are deliberately not retained.
  model_->set_voice("british_female");
}

PocketEngine::~PocketEngine() = default;

void PocketEngine::render(const std::string& text, const std::string& voice,
                          const PocketFrameSink& sink) {
  // Affinity and priority are per thread: the constructor only tuned the
  // thread that loaded the model, while rendering runs on the app's speech
  // worker. Untuned, that worker ran on efficiency cores at default priority
  // and rendered at ~0.4x real time on a mid-range phone.
  static thread_local bool tuned = false;
  if (!tuned) {
    preferFastCores();
    preferAudioPriority();
    tuned = true;
  }
  throwIfCancelled();
  check(!text.empty() && text.size() <= 1600, "Pocket text exceeds local limit");
  model_->set_voice(voice);
  throwIfCancelled();

  model_->synthesize(text, "en", [&](const float* samples, size_t n, bool final) {
    throwIfCancelled();
    if (final) return;
    check(n > 0 && n <= static_cast<size_t>(kMaxFrameSamples),
          "Invalid Pocket frame size");
    for (size_t i = 0; i < n; ++i) {
      check(std::isfinite(samples[i]) && std::abs(samples[i]) <= 1,
            "Invalid Pocket PCM");
    }
    sink(samples, static_cast<int>(n));
  });

  throwIfCancelled();
  // Reject exhaustion rather than silently claiming a truncated utterance
  // finished: the caller falls back to cloud audio instead of clipping speech.
  check(model_->last_metrics().stopped_on_eos,
        "Pocket context exhausted before speech finished");
}

int PocketEngine::warmVoices(const std::vector<std::string>& voices) {
  int loaded = 0;
  for (const auto& voice : voices) {
    if (cancelled_.load()) break;
    try {
      model_->set_voice(voice);
      ++loaded;
    } catch (const std::exception&) {
      // A missing or broken adapter is the render's problem to report, not the
      // warm-up's: it must not prevent the conversation from starting.
    }
  }
  return loaded;
}

void PocketEngine::cancel() {
  cancelled_.store(true);
  if (model_) model_->cancel();
}

void PocketEngine::reset() { cancelled_.store(false); }

void PocketEngine::throwIfCancelled() const {
  if (cancelled_.load()) throw PocketCancelled{};
}

}  // namespace pocket
