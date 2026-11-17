// Private line-oriented worker. Models remain loaded until stdin closes.
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include "json.hpp"
#include "whisper.h"
using json = nlohmann::ordered_json;

int main(int argc, char **argv) {
    if (argc != 4) {
        std::cerr << "Usage: vtracker-whisper-worker MODEL LANGUAGE VAD_MODEL_OR_EMPTY\n";
        return 2;
    }
    try {
        auto options = whisper_context_default_params();
        auto context = std::unique_ptr<whisper_context, decltype(&whisper_free)>(
            whisper_init_from_file_with_params(argv[1], options), whisper_free);
        if (!context) throw std::runtime_error("Cannot load Whisper model");
        auto params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
        params.n_threads = 2;
        params.language = argv[2];
        params.n_max_text_ctx = 0;
        params.no_context = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.beam_search.beam_size = 5;
        params.vad = argv[3][0] != '\0';
        params.vad_model_path = argv[3];
        params.vad_params = whisper_vad_default_params();
        params.vad_params.threshold = 0.5f;
        params.vad_params.min_speech_duration_ms = 250;
        params.vad_params.min_silence_duration_ms = 100;
        params.vad_params.speech_pad_ms = 30;
        params.vad_params.samples_overlap = 0.1f;
        std::string line;
        while (std::getline(std::cin, line)) {
            try {
                auto request = json::parse(line);
                std::ifstream input(request.at("pcm").get<std::string>(), std::ios::binary | std::ios::ate);
                const auto bytes = input.tellg();
                if (!input || bytes <= 0 || bytes > 16000 * 4 * 180 || bytes % 4 != 0)
                    throw std::runtime_error("Expected up to 180 seconds of float32 mono 16kHz PCM");
                std::vector<float> samples(static_cast<size_t>(bytes) / 4);
                input.seekg(0);
                input.read(reinterpret_cast<char *>(samples.data()), bytes);
                if (!input) throw std::runtime_error("Cannot read PCM");
                if (whisper_full(context.get(), params, samples.data(), static_cast<int>(samples.size())) != 0)
                    throw std::runtime_error("Whisper inference failed");
                auto rows = json::array();
                for (int i = 0; i < whisper_full_n_segments(context.get()); ++i) {
                    rows.push_back({{"text", whisper_full_get_segment_text(context.get(), i)},
                        {"offsets", {{"from", whisper_full_get_segment_t0(context.get(), i) * 10},
                                     {"to", whisper_full_get_segment_t1(context.get(), i) * 10}}}});
                }
                std::cout << json({{"transcription", rows}}).dump() << std::endl;
            } catch (const std::exception &error) {
                std::cout << json({{"error", error.what()}}).dump() << std::endl;
            }
        }
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
