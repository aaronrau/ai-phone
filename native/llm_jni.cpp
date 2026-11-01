// On-device language models for the receptionist.
//
// Several independent engines can be resident at once (the Gemma generator and
// a small decision model). Each engine owns one model and one context.
//
// generate(): a complete rendered conversation is decoded with the longest
//   possible reuse of the resident KV cache, optionally constrained by a GBNF
//   grammar so tool calls are always well-formed JSON.
// decide():   scores a fixed list of answer options as continuations of the
//   prompt and returns their normalised probabilities, a calibrated
//   confidence signal for routing a turn or escalating it.
//
// Hybrid/recurrent models (e.g. LFM2) cannot roll their state back to an
// arbitrary position, so a state checkpoint is kept after the static prompt
// prefix and restored instead.

#include <jni.h>
#include <android/log.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include "llama.h"

namespace {

constexpr const char* kTag = "ReceptionistLlm";

void log(const std::string& message) { __android_log_print(ANDROID_LOG_INFO, kTag, "%s", message.c_str()); }

void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

std::string fromBytes(JNIEnv* env, jbyteArray value) {
    if (value == nullptr) return {};
    const jsize n = env->GetArrayLength(value);
    std::string result(static_cast<size_t>(n), '\0');
    env->GetByteArrayRegion(value, 0, n, reinterpret_cast<jbyte*>(result.data()));
    return result;
}

jbyteArray toBytes(JNIEnv* env, const std::string& value) {
    jbyteArray result = env->NewByteArray(static_cast<jsize>(value.size()));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(value.size()),
                                        reinterpret_cast<const jbyte*>(value.data()));
    return result;
}

std::string toString(JNIEnv* env, jstring value) {
    if (value == nullptr) return {};
    const char* raw = env->GetStringUTFChars(value, nullptr);
    std::string result(raw ? raw : "");
    if (raw) env->ReleaseStringUTFChars(value, raw);
    return result;
}

void fail(JNIEnv* env, const std::exception& error) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), error.what());
}

long long since(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
}

// Threads inherit CPU affinity from their creator; another engine may have
// pinned the thread that created this worker. Inference must see every core.
void unpin_current_thread() {
    cpu_set_t all;
    CPU_ZERO(&all);
    const long count = sysconf(_SC_NPROCESSORS_CONF);
    for (long cpu = 0; cpu < count && cpu < CPU_SETSIZE; ++cpu) CPU_SET(cpu, &all);
    sched_setaffinity(0, sizeof(all), &all);
}

int batch_threads() {
    const long count = sysconf(_SC_NPROCESSORS_CONF);
    return static_cast<int>(std::max(1L, std::min(8L, count)));
}

size_t complete_utf8(const std::string& value) {
    size_t pos = 0;
    while (pos < value.size()) {
        const auto c = static_cast<unsigned char>(value[pos]);
        const size_t n = c < 0x80 ? 1 : (c & 0xe0) == 0xc0 ? 2 : (c & 0xf0) == 0xe0 ? 3 : 4;
        if (pos + n > value.size()) break;
        pos += n;
    }
    return pos;
}

bool abort_work(void* data) { return static_cast<std::atomic<bool>*>(data)->load(); }

struct Engine {
    std::atomic<bool> cancelled{false};
    llama_model* model = nullptr;
    llama_context* context = nullptr;
    std::string path;
    int context_size = 0;
    bool rollback = true;               // false for recurrent/hybrid memory
    std::vector<llama_token> cached;    // tokens whose state is resident
    // Saved states after static prompt prefixes (most recent first). They let
    // alternating prompts (decision vs. slot extraction) skip re-reading their
    // instructions, and are the only reuse possible without rollback.
    struct Checkpoint {
        std::vector<llama_token> tokens;
        std::vector<uint8_t> state;
    };
    std::vector<Checkpoint> checkpoints;
    static constexpr size_t kMaxCheckpoints = 3;

    ~Engine() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }

    const llama_vocab* vocab() const { return llama_model_get_vocab(model); }

    std::vector<llama_token> tokenize(const std::string& text, bool special_prefix) const {
        const bool add_special = special_prefix && text.rfind("<bos>", 0) != 0;
        int n = llama_tokenize(vocab(), text.data(), static_cast<int>(text.size()), nullptr, 0, add_special, true);
        require(n <= 0, "Tokenization failed");
        std::vector<llama_token> tokens(-n);
        if (tokens.empty()) return tokens;
        n = llama_tokenize(vocab(), text.data(), static_cast<int>(text.size()), tokens.data(),
                           static_cast<int>(tokens.size()), add_special, true);
        require(n >= 0, "Tokenization failed");
        tokens.resize(n);
        return tokens;
    }

    std::string piece(llama_token token) const {
        char buffer[256];
        int n = llama_token_to_piece(vocab(), token, buffer, sizeof(buffer), 0, false);
        if (n < 0) {
            std::string large(-n, '\0');
            n = llama_token_to_piece(vocab(), token, large.data(), static_cast<int>(large.size()), 0, false);
            return n > 0 ? large.substr(0, n) : std::string();
        }
        return std::string(buffer, n);
    }

    void decode_range(const std::vector<llama_token>& tokens, size_t from, int batch) {
        for (size_t i = from; i < tokens.size(); i += batch) {
            require(!cancelled.load(), "Cancelled");
            const int count = static_cast<int>(std::min<size_t>(batch, tokens.size() - i));
            auto view = llama_batch_get_one(const_cast<llama_token*>(tokens.data() + i), count);
            require(llama_decode(context, view) == 0, cancelled.load() ? "Cancelled" : "Prompt decode failed");
            cached.insert(cached.end(), tokens.begin() + i, tokens.begin() + i + count);
        }
    }

    void reset_memory() {
        llama_memory_clear(llama_get_memory(context), false);
        cached.clear();
    }

    void save_checkpoint() {
        Checkpoint saved;
        saved.state.resize(llama_state_seq_get_size(context, 0));
        saved.state.resize(llama_state_seq_get_data(context, saved.state.data(), saved.state.size(), 0));
        saved.tokens = cached;
        checkpoints.erase(std::remove_if(checkpoints.begin(), checkpoints.end(),
            [&](const Checkpoint& c) { return c.tokens == saved.tokens; }), checkpoints.end());
        checkpoints.insert(checkpoints.begin(), std::move(saved));
        if (checkpoints.size() > kMaxCheckpoints) checkpoints.pop_back();
    }

    /// Restores the checkpoint whose tokens equal the first `count` prompt tokens.
    bool restore_checkpoint(const std::vector<llama_token>& tokens, size_t count) {
        for (size_t i = 0; i < checkpoints.size(); ++i) {
            auto& c = checkpoints[i];
            if (c.tokens.size() != count || shared_prefix(tokens, c.tokens) != count) continue;
            llama_memory_clear(llama_get_memory(context), false);
            if (llama_state_seq_set_data(context, c.state.data(), c.state.size(), 0) == 0) {
                checkpoints.erase(checkpoints.begin() + static_cast<long>(i));
                cached.clear();
                return false;
            }
            cached = c.tokens;
            if (i != 0) std::rotate(checkpoints.begin(), checkpoints.begin() + static_cast<long>(i),
                                    checkpoints.begin() + static_cast<long>(i) + 1);
            return true;
        }
        return false;
    }

    static size_t shared_prefix(const std::vector<llama_token>& a, const std::vector<llama_token>& b) {
        size_t n = 0;
        while (n < a.size() && n < b.size() && a[n] == b[n]) ++n;
        return n;
    }

    /// Makes the resident state equal to `tokens` (logits valid for the last
    /// token). `static_tokens` marks a prefix worth checkpointing. Returns the
    /// number of tokens reused.
    size_t prepare(const std::vector<llama_token>& tokens, size_t static_tokens) {
        require(!tokens.empty(), "Empty prompt");
        const bool has_static = static_tokens > 0 && static_tokens < tokens.size();
        size_t prefix = shared_prefix(tokens, cached);
        // Fast paths: plain KV rollback, or an exact extension without rollback.
        if (rollback && (!has_static || prefix >= static_tokens)) {
            prefix = std::min(prefix, tokens.size() - 1);
            if (llama_memory_seq_rm(llama_get_memory(context), 0, static_cast<llama_pos>(prefix), -1)) {
                cached.resize(prefix);
                decode_range(tokens, prefix, 256);
                return prefix;
            }
        }
        if (!rollback && prefix == cached.size() && prefix < tokens.size() && (!has_static || prefix >= static_tokens)) {
            decode_range(tokens, prefix, 256);
            return prefix;
        }
        // Otherwise start from a saved static-prefix checkpoint, or build one.
        size_t reused = 0;
        if (has_static && restore_checkpoint(tokens, static_tokens)) {
            reused = static_tokens;
        } else {
            reset_memory();
            if (has_static) {
                decode_range(std::vector<llama_token>(tokens.begin(), tokens.begin() + static_tokens), 0, 256);
                save_checkpoint();
            }
        }
        decode_range(tokens, cached.size(), 256);
        return reused;
    }

    /// Number of leading prompt tokens that equal the tokenized static prefix.
    size_t static_count(const std::vector<llama_token>& tokens, const std::string& static_text) const {
        if (static_text.empty()) return 0;
        const auto fixed = tokenize(static_text, true);
        const size_t n = shared_prefix(tokens, fixed);
        return n == fixed.size() ? n : 0;
    }
};

std::mutex engines_lock;
std::vector<std::unique_ptr<Engine>> engines;  // index + 1 == handle

Engine& engine(jlong handle) {
    std::lock_guard<std::mutex> guard(engines_lock);
    require(handle > 0 && static_cast<size_t>(handle) <= engines.size() && engines[handle - 1], "Model is not loaded");
    return *engines[handle - 1];
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativeLoad(JNIEnv* env, jobject, jstring path, jint n_ctx, jint threads) {
    try {
        unpin_current_thread();
        llama_backend_init();
        const auto start = std::chrono::steady_clock::now();
        auto created = std::make_unique<Engine>();
        created->path = toString(env, path);
        created->model = llama_model_load_from_file(created->path.c_str(), llama_model_default_params());
        require(created->model != nullptr, "Cannot load the provisioned model");
        auto cparams = llama_context_default_params();
        cparams.n_ctx = n_ctx;
        cparams.n_batch = 256;
        cparams.n_ubatch = 256;
        cparams.n_threads = threads;
        cparams.n_threads_batch = std::max(static_cast<int>(threads), batch_threads());
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        cparams.swa_full = true;   // allows rollback to any shared prefix
        cparams.kv_unified = true;
        cparams.abort_callback = abort_work;
        cparams.abort_callback_data = &created->cancelled;
        created->context = llama_init_from_model(created->model, cparams);
        require(created->context != nullptr, "Not enough memory for the model context");
        created->context_size = n_ctx;
        created->rollback = !llama_model_is_recurrent(created->model) && !llama_model_is_hybrid(created->model);
        log("model_loaded ms=" + std::to_string(since(start)) + " ctx=" + std::to_string(n_ctx) +
            " threads=" + std::to_string(threads) + " batch_threads=" + std::to_string(cparams.n_threads_batch) +
            " rollback=" + std::to_string(created->rollback) + " path=" +
            created->path.substr(created->path.find_last_of('/') + 1));
        std::lock_guard<std::mutex> guard(engines_lock);
        engines.push_back(std::move(created));
        return static_cast<jlong>(engines.size());
    } catch (const std::exception& error) {
        fail(env, error);
        return 0;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativeUnload(JNIEnv*, jobject, jlong handle) {
    std::lock_guard<std::mutex> guard(engines_lock);
    if (handle > 0 && static_cast<size_t>(handle) <= engines.size()) engines[handle - 1].reset();
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativeCancel(JNIEnv*, jobject, jlong handle) {
    std::lock_guard<std::mutex> guard(engines_lock);
    if (handle > 0 && static_cast<size_t>(handle) <= engines.size() && engines[handle - 1]) {
        engines[handle - 1]->cancelled = true;
    }
}

/// Prefills `prompt` without sampling. Returns the number of new tokens.
extern "C" JNIEXPORT jint JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativePrefill(JNIEnv* env, jobject, jlong handle, jbyteArray prompt,
                                                          jbyteArray static_prefix) {
    try {
        unpin_current_thread();
        auto& e = engine(handle);
        e.cancelled = false;
        const auto tokens = e.tokenize(fromBytes(env, prompt), true);
        require(tokens.size() + 8 < static_cast<size_t>(e.context_size), "Prompt exceeds the context");
        const size_t reused = e.prepare(tokens, e.static_count(tokens, fromBytes(env, static_prefix)));
        return static_cast<jint>(tokens.size() - reused);
    } catch (const std::exception& error) {
        fail(env, error);
        return -1;
    }
}

/// Scores each option as a continuation of `prompt`. Returns natural-log
/// probabilities normalised over the options (sum of token log-probs, then a
/// softmax across options), followed by one extra element: elapsed ms.
extern "C" JNIEXPORT jfloatArray JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativeDecide(JNIEnv* env, jobject, jlong handle, jbyteArray prompt,
                                                         jbyteArray static_prefix, jobjectArray options) {
    llama_batch batch{};
    bool batch_ready = false;
    try {
        unpin_current_thread();
        auto& e = engine(handle);
        e.cancelled = false;
        const auto start = std::chrono::steady_clock::now();
        const auto tokens = e.tokenize(fromBytes(env, prompt), true);
        const jsize count = env->GetArrayLength(options);
        require(count > 0, "No options");
        std::vector<std::vector<llama_token>> option_tokens;
        size_t longest = 1;
        for (jsize i = 0; i < count; ++i) {
            auto bytes = static_cast<jbyteArray>(env->GetObjectArrayElement(options, i));
            option_tokens.push_back(e.tokenize(fromBytes(env, bytes), false));
            env->DeleteLocalRef(bytes);
            require(!option_tokens.back().empty(), "Empty option");
            longest = std::max(longest, option_tokens.back().size());
        }
        require(tokens.size() + longest + 8 < static_cast<size_t>(e.context_size), "Prompt exceeds the context");
        const size_t reused = e.prepare(tokens, e.static_count(tokens, fromBytes(env, static_prefix)));
        const auto prefilled = since(start);

        const int n_vocab = llama_vocab_n_tokens(e.vocab());
        auto log_softmax_at = [&](const float* logits, llama_token token) {
            float max_logit = -INFINITY;
            for (int i = 0; i < n_vocab; ++i) max_logit = std::max(max_logit, logits[i]);
            double sum = 0;
            for (int i = 0; i < n_vocab; ++i) sum += std::exp(static_cast<double>(logits[i] - max_logit));
            return static_cast<double>(logits[token] - max_logit) - std::log(sum);
        };
        const float* prompt_logits = llama_get_logits_ith(e.context, -1);
        std::vector<float> first(prompt_logits, prompt_logits + n_vocab);

        std::vector<uint8_t> snapshot;
        if (!e.rollback) {
            snapshot.resize(llama_state_seq_get_size(e.context, 0));
            snapshot.resize(llama_state_seq_get_data(e.context, snapshot.data(), snapshot.size(), 0));
        }
        batch = llama_batch_init(static_cast<int32_t>(longest), 0, 1);
        batch_ready = true;
        const auto base = static_cast<llama_pos>(tokens.size());
        std::vector<double> scores;
        for (const auto& option : option_tokens) {
            double score = log_softmax_at(first.data(), option[0]);
            if (option.size() > 1) {
                batch.n_tokens = 0;
                for (size_t i = 0; i + 1 < option.size(); ++i) {
                    batch.token[batch.n_tokens] = option[i];
                    batch.pos[batch.n_tokens] = base + static_cast<llama_pos>(i);
                    batch.n_seq_id[batch.n_tokens] = 1;
                    batch.seq_id[batch.n_tokens][0] = 0;
                    batch.logits[batch.n_tokens] = 1;
                    ++batch.n_tokens;
                }
                require(llama_decode(e.context, batch) == 0, "Option decode failed");
                for (size_t i = 1; i < option.size(); ++i) {
                    score += log_softmax_at(llama_get_logits_ith(e.context, static_cast<int32_t>(i - 1)), option[i]);
                }
                if (e.rollback) {
                    require(llama_memory_seq_rm(llama_get_memory(e.context), 0, base, -1), "Rollback failed");
                } else {
                    llama_memory_clear(llama_get_memory(e.context), false);
                    require(llama_state_seq_set_data(e.context, snapshot.data(), snapshot.size(), 0) > 0,
                            "State restore failed");
                }
            }
            scores.push_back(score);
        }
        llama_batch_free(batch);
        batch_ready = false;
        e.cached = tokens;

        double max_score = -INFINITY;
        for (double s : scores) max_score = std::max(max_score, s);
        double total = 0;
        for (double s : scores) total += std::exp(s - max_score);
        std::vector<float> result;
        for (double s : scores) result.push_back(static_cast<float>(s - max_score - std::log(total)));
        const auto elapsed = since(start);
        result.push_back(static_cast<float>(elapsed));
        log("decide prompt_tokens=" + std::to_string(tokens.size()) + " reused=" + std::to_string(reused) +
            " prefill_ms=" + std::to_string(prefilled) + " total_ms=" + std::to_string(elapsed) +
            " options=" + std::to_string(count));
        jfloatArray out = env->NewFloatArray(static_cast<jsize>(result.size()));
        env->SetFloatArrayRegion(out, 0, static_cast<jsize>(result.size()), result.data());
        return out;
    } catch (const std::exception& error) {
        if (batch_ready) llama_batch_free(batch);
        try { engine(handle).reset_memory(); } catch (...) {}
        fail(env, error);
        return nullptr;
    }
}

/// Generates a reply to a complete rendered prompt. Every decoded UTF-8 chunk
/// is delivered to `onToken(byte[])` on `sink`. Returns the full text.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_ai_local_receptionist_engine_LlmEngine_nativeGenerate(JNIEnv* env, jobject, jlong handle, jbyteArray prompt,
                                                           jbyteArray static_prefix, jstring grammar,
                                                           jint max_tokens, jfloat temperature, jobject sink) {
    llama_sampler* sampler = nullptr;
    llama_sampler* grammar_sampler = nullptr;
    Engine* current = nullptr;
    try {
        unpin_current_thread();
        auto& e = engine(handle);
        current = &e;
        e.cancelled = false;
        const auto start = std::chrono::steady_clock::now();
        const auto* vocab = e.vocab();
        const auto tokens = e.tokenize(fromBytes(env, prompt), true);
        require(tokens.size() + max_tokens + 8 < static_cast<size_t>(e.context_size),
                "Conversation exceeds the context window");
        const size_t reused = e.prepare(tokens, e.static_count(tokens, fromBytes(env, static_prefix)));
        const auto prefilled = std::chrono::steady_clock::now();

        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.05f, 0.0f, 0.0f));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95f, 1));
        if (temperature <= 0.0f) {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        }
        const auto grammar_text = toString(env, grammar);
        if (!grammar_text.empty()) {
            grammar_sampler = llama_sampler_init_grammar(vocab, grammar_text.c_str(), "root");
            require(grammar_sampler != nullptr, "Invalid output grammar");
        }
        const int n_vocab = llama_vocab_n_tokens(vocab);
        int grammar_resamples = 0;
        std::vector<llama_token_data> candidates(static_cast<size_t>(n_vocab));
        // Sample without the grammar first and only check the chosen token;
        // constraining a large vocabulary every step is far too slow.
        auto sample_next = [&]() -> llama_token {
            const float* logits = llama_get_logits_ith(e.context, -1);
            auto fill = [&]() {
                for (int i = 0; i < n_vocab; ++i) candidates[i] = llama_token_data{i, logits[i], 0.0f};
                return llama_token_data_array{candidates.data(), candidates.size(), -1, false};
            };
            auto array = fill();
            llama_sampler_apply(sampler, &array);
            llama_token id = array.data[array.selected].id;
            if (grammar_sampler) {
                llama_token_data single{id, 1.0f, 0.0f};
                llama_token_data_array check{&single, 1, -1, false};
                llama_sampler_apply(grammar_sampler, &check);
                if (check.data[0].logit == -INFINITY) {
                    ++grammar_resamples;
                    array = fill();
                    llama_sampler_apply(grammar_sampler, &array);
                    llama_sampler_apply(sampler, &array);
                    id = array.data[array.selected].id;
                }
                llama_sampler_accept(grammar_sampler, id);
            }
            llama_sampler_accept(sampler, id);
            return id;
        };

        jmethodID on_token = nullptr;
        if (sink != nullptr) on_token = env->GetMethodID(env->GetObjectClass(sink), "onToken", "([B)V");
        std::string output, pending;
        int generated = 0;
        long long first_token_ms = -1;
        for (; generated < max_tokens; ++generated) {
            require(!e.cancelled.load(), "Cancelled");
            const llama_token next = sample_next();
            if (llama_vocab_is_eog(vocab, next)) break;
            if (first_token_ms < 0) first_token_ms = since(start);
            pending += e.piece(next);
            const size_t ready = complete_utf8(pending);
            if (ready > 0) {
                const auto text = pending.substr(0, ready);
                pending.erase(0, ready);
                output += text;
                if (on_token) {
                    jbyteArray chunk = toBytes(env, text);
                    env->CallVoidMethod(sink, on_token, chunk);
                    env->DeleteLocalRef(chunk);
                    if (env->ExceptionCheck()) throw std::runtime_error("Token callback failed");
                }
            }
            llama_token token = next;
            auto view = llama_batch_get_one(&token, 1);
            require(llama_decode(e.context, view) == 0, e.cancelled.load() ? "Cancelled" : "Decode failed");
            e.cached.push_back(next);
        }
        llama_sampler_free(sampler);
        sampler = nullptr;
        if (grammar_sampler) { llama_sampler_free(grammar_sampler); grammar_sampler = nullptr; }
        log("generate prompt_tokens=" + std::to_string(tokens.size()) + " reused=" + std::to_string(reused) +
            " prefill_ms=" + std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(prefilled - start).count()) +
            " first_token_ms=" + std::to_string(first_token_ms) + " total_ms=" + std::to_string(since(start)) +
            " generated=" + std::to_string(generated) + " resamples=" + std::to_string(grammar_resamples));
        return toBytes(env, output);
    } catch (const std::exception& error) {
        if (sampler) llama_sampler_free(sampler);
        if (grammar_sampler) llama_sampler_free(grammar_sampler);
        // `cached` lists only fully decoded tokens; a cancellation keeps the
        // reusable prefix, any other failure starts fresh next time.
        if (current && (!current->cancelled.load() || !current->rollback)) current->reset_memory();
        fail(env, error);
        return nullptr;
    }
}

// ---------------------------------------------------------------- embeddings

namespace {

/// A small sentence-embedding model (e.g. bge-small) for intent detection.
struct Embedder {
    llama_model* model = nullptr;
    llama_context* context = nullptr;
    int dimensions = 0;
    int context_size = 0;
    std::mutex lock;

    ~Embedder() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

std::unique_ptr<Embedder> embedder;
std::mutex embedder_lock;

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_ai_local_receptionist_engine_EmbeddingEngine_nativeLoad(JNIEnv* env, jobject, jstring path, jint threads) {
    try {
        unpin_current_thread();
        llama_backend_init();
        const auto start = std::chrono::steady_clock::now();
        auto created = std::make_unique<Embedder>();
        const std::string file = toString(env, path);
        created->model = llama_model_load_from_file(file.c_str(), llama_model_default_params());
        require(created->model != nullptr, "Cannot load the embedding model");
        auto cparams = llama_context_default_params();
        cparams.embeddings = true;
        cparams.n_ctx = 512;
        cparams.n_batch = 512;
        cparams.n_ubatch = 512;
        cparams.n_seq_max = 1;
        cparams.n_threads = threads;
        cparams.n_threads_batch = threads;
        cparams.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED;  // the model's own pooling (CLS or mean)
        created->context = llama_init_from_model(created->model, cparams);
        require(created->context != nullptr, "Not enough memory for the embedding model");
        created->dimensions = llama_model_n_embd(created->model);
        created->context_size = 512;
        log("embedding_loaded ms=" + std::to_string(since(start)) + " dims=" + std::to_string(created->dimensions) +
            " pooling=" + std::to_string(static_cast<int>(llama_pooling_type(created->context))));
        std::lock_guard<std::mutex> guard(embedder_lock);
        embedder = std::move(created);
        return embedder->dimensions;
    } catch (const std::exception& error) {
        fail(env, error);
        return 0;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_ai_local_receptionist_engine_EmbeddingEngine_nativeUnload(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> guard(embedder_lock);
    embedder.reset();
}

/// L2-normalised sentence embedding of [text] (cosine similarity is then a dot product).
extern "C" JNIEXPORT jfloatArray JNICALL
Java_ai_local_receptionist_engine_EmbeddingEngine_nativeEmbed(JNIEnv* env, jobject, jbyteArray text) {
    try {
        std::lock_guard<std::mutex> guard(embedder_lock);
        require(embedder != nullptr, "Embedding model is not loaded");
        Embedder& e = *embedder;
        std::lock_guard<std::mutex> busy(e.lock);
        const std::string input = fromBytes(env, text);
        const llama_vocab* vocab = llama_model_get_vocab(e.model);
        int n = llama_tokenize(vocab, input.data(), static_cast<int>(input.size()), nullptr, 0, true, false);
        std::vector<llama_token> tokens(static_cast<size_t>(n < 0 ? -n : n));
        n = llama_tokenize(vocab, input.data(), static_cast<int>(input.size()), tokens.data(),
                           static_cast<int>(tokens.size()), true, false);
        require(n >= 0, "Tokenization failed");
        tokens.resize(static_cast<size_t>(std::min(n, e.context_size)));
        require(!tokens.empty(), "Nothing to embed");

        llama_memory_clear(llama_get_memory(e.context), true);
        llama_batch batch = llama_batch_init(static_cast<int>(tokens.size()), 0, 1);
        for (size_t i = 0; i < tokens.size(); ++i) {
            batch.token[i] = tokens[i];
            batch.pos[i] = static_cast<llama_pos>(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i] = true;
        }
        batch.n_tokens = static_cast<int>(tokens.size());
        const bool encoder_only = llama_model_has_encoder(e.model) && !llama_model_has_decoder(e.model);
        const int status = encoder_only ? llama_encode(e.context, batch) : llama_decode(e.context, batch);
        llama_batch_free(batch);
        require(status == 0, "Embedding failed");

        const float* pooled = llama_get_embeddings_seq(e.context, 0);
        if (pooled == nullptr) pooled = llama_get_embeddings_ith(e.context, -1);
        require(pooled != nullptr, "No embedding produced");
        std::vector<float> out(pooled, pooled + e.dimensions);
        double norm = 0;
        for (float v : out) norm += static_cast<double>(v) * v;
        norm = std::sqrt(norm);
        if (norm > 0) for (float& v : out) v = static_cast<float>(v / norm);
        jfloatArray result = env->NewFloatArray(e.dimensions);
        env->SetFloatArrayRegion(result, 0, e.dimensions, out.data());
        return result;
    } catch (const std::exception& error) {
        fail(env, error);
        return nullptr;
    }
}
