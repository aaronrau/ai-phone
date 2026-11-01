// JNI edge for the shared Pocket renderer: renders text and hands PCM16 frames
// (24 kHz mono) to Kotlin as they are produced, so playback can start early.

#include "pocket_core.h"

#include <jni.h>

#include <cmath>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::string toString(JNIEnv* env, jstring value) {
  if (value == nullptr) throw std::runtime_error("Missing Pocket argument");
  const char* raw = env->GetStringUTFChars(value, nullptr);
  if (raw == nullptr) throw std::runtime_error("Invalid Pocket argument");
  std::string result(raw);
  env->ReleaseStringUTFChars(value, raw);
  return result;
}

void fail(JNIEnv* env, const std::exception& error) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), error.what());
}

pocket::PocketEngine& engine(jlong pointer) {
  if (pointer == 0) throw std::runtime_error("Pocket is not initialized");
  return *reinterpret_cast<pocket::PocketEngine*>(pointer);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeCreate(JNIEnv* env, jobject, jstring directory) {
  try {
    return reinterpret_cast<jlong>(new pocket::PocketEngine(toString(env, directory)));
  } catch (const std::exception& error) {
    fail(env, error);
    return 0;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeReset(JNIEnv*, jobject, jlong pointer) {
  if (pointer != 0) reinterpret_cast<pocket::PocketEngine*>(pointer)->reset();
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeCancel(JNIEnv*, jobject, jlong pointer) {
  if (pointer != 0) reinterpret_cast<pocket::PocketEngine*>(pointer)->cancel();
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeDestroy(JNIEnv*, jobject, jlong pointer) {
  delete reinterpret_cast<pocket::PocketEngine*>(pointer);
}

extern "C" JNIEXPORT jint JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeWarm(JNIEnv* env, jobject, jlong pointer,
                                                       jstring voice) {
  try {
    return engine(pointer).warmVoices({toString(env, voice)});
  } catch (const std::exception& error) {
    fail(env, error);
    return 0;
  }
}

/// Renders `text`; every frame is passed to `onFrame([B)V` on the calling
/// object. Returns false when cancelled.
extern "C" JNIEXPORT jboolean JNICALL
Java_ai_local_receptionist_engine_PocketTts_nativeRender(JNIEnv* env, jobject self, jlong pointer,
                                                         jstring text, jstring voice) {
  try {
    auto& e = engine(pointer);
    jmethodID onFrame = env->GetMethodID(env->GetObjectClass(self), "onFrame", "([B)V");
    if (onFrame == nullptr) throw std::runtime_error("Pocket frame callback unavailable");
    std::vector<int16_t> frame;
    e.render(toString(env, text), toString(env, voice), [&](const float* samples, int count) {
      frame.resize(static_cast<size_t>(count));
      for (int i = 0; i < count; ++i) {
        const float clamped = std::fmax(-1.0f, std::fmin(1.0f, samples[i]));
        frame[i] = static_cast<int16_t>(std::lround(clamped * 32767.0f));
      }
      const jsize bytes = static_cast<jsize>(count) * 2;
      jbyteArray chunk = env->NewByteArray(bytes);
      if (chunk == nullptr) throw std::runtime_error("Pocket frame allocation failed");
      env->SetByteArrayRegion(chunk, 0, bytes, reinterpret_cast<const jbyte*>(frame.data()));
      env->CallVoidMethod(self, onFrame, chunk);
      env->DeleteLocalRef(chunk);
    });
    return JNI_TRUE;
  } catch (const pocket::PocketCancelled&) {
    return JNI_FALSE;
  } catch (const std::exception& error) {
    fail(env, error);
    return JNI_FALSE;
  }
}
