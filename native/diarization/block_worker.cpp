// Private worker for speaker separation and cross-block comparison.
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <vector>
#include "json.hpp"
#include "sherpa-onnx/c-api/c-api.h"

using json = nlohmann::ordered_json;
constexpr int rate = 16000;

static json infer(const json &request, const SherpaOnnxOfflineSpeakerDiarization *diarizer,
                  const SherpaOnnxSpeakerEmbeddingExtractor *extractor) {
    const auto path = request.at("wav").get<std::string>();
    auto wave = std::unique_ptr<const SherpaOnnxWave, decltype(&SherpaOnnxFreeWave)>(
        SherpaOnnxReadWave(path.c_str()), SherpaOnnxFreeWave);
    if (!wave || wave->sample_rate != rate || wave->num_samples <= 0 || wave->num_samples > rate * 180)
        throw std::runtime_error("Expected mono 16kHz WAV of up to 180 seconds");
    auto result = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationResult,
                                  decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroyResult)>(
        SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, wave->samples, wave->num_samples),
        SherpaOnnxOfflineSpeakerDiarizationDestroyResult);
    if (!result) throw std::runtime_error("Speaker separation failed");
    const int count = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result.get());
    auto turns = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationSegment,
                                 decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroySegment)>(
        SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result.get()),
        SherpaOnnxOfflineSpeakerDiarizationDestroySegment);
    if (count < 0 || (count > 0 && !turns)) throw std::runtime_error("Invalid speaker turns");

    auto rows = json::array();
    std::map<int, std::vector<float>> clean_audio;
    for (int i = 0; i < count; ++i) {
        const auto &turn = turns.get()[i];
        if (!std::isfinite(turn.start) || !std::isfinite(turn.end) ||
            turn.start < 0 || turn.end <= turn.start || turn.speaker < 0)
            throw std::runtime_error("Invalid speaker interval");
        auto from = std::llround(turn.start * 1000);
        auto to = std::min(std::llround(turn.end * 1000), static_cast<long long>(wave->num_samples / 16));
        if (to <= from) continue;
        rows.push_back({{"start_ms", from}, {"end_ms", to}, {"speaker", turn.speaker}});
        bool overlaps = false;
        for (int j = 0; j < count && turns.get()[j].start < turn.end; ++j) {
            const auto &other = turns.get()[j];
            if (other.speaker != turn.speaker && other.end > turn.start) {
                overlaps = true;
                break;
            }
        }
        if (overlaps || to - from < 400) continue;
        auto &samples = clean_audio[turn.speaker];
        const size_t amount = std::min<size_t>(16 * (to - from), rate * 12 - samples.size());
        const float *begin = wave->samples + 16 * from;
        samples.insert(samples.end(), begin, begin + amount);
    }

    auto voices = json::object();
    const int dim = SherpaOnnxSpeakerEmbeddingExtractorDim(extractor);
    for (const auto &[speaker, samples] : clean_audio) {
        if (samples.size() < rate * 6 || dim <= 0 || dim > 4096) continue;
        auto stream = std::unique_ptr<const SherpaOnnxOnlineStream, decltype(&SherpaOnnxDestroyOnlineStream)>(
            SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor), SherpaOnnxDestroyOnlineStream);
        if (!stream) continue;
        SherpaOnnxOnlineStreamAcceptWaveform(stream.get(), rate, samples.data(), static_cast<int>(samples.size()));
        SherpaOnnxOnlineStreamInputFinished(stream.get());
        if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream.get())) continue;
        auto values = std::unique_ptr<const float, decltype(&SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding)>(
            SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream.get()),
            SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);
        if (values && std::all_of(values.get(), values.get() + dim, [](float value) { return std::isfinite(value); }))
            voices[std::to_string(speaker)] = std::vector<float>(values.get(), values.get() + dim);
    }
    return {{"turns", rows}, {"voices", voices}};
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return 2;
    try {
        const int threads = argc == 5 ? std::stoi(argv[4]) : 2;
        if (threads < 1 || threads > 4) throw std::runtime_error("Speaker worker expects 1..4 CPU threads");
        SherpaOnnxOfflineSpeakerDiarizationConfig config{};
        config.segmentation.pyannote.model = argv[1];
        config.segmentation.pyannote.window_shift_ratio = 0.2f;
        config.segmentation.num_threads = threads;
        config.segmentation.provider = "cpu";
        config.embedding.model = argv[2];
        config.embedding.num_threads = threads;
        config.embedding.provider = "cpu";
        config.clustering.num_clusters = 0;
        config.clustering.threshold = std::stof(argv[3]);
        config.min_duration_on = 0.2f;
        config.min_duration_off = 0.5f;
        auto diarizer = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarization,
                                       decltype(&SherpaOnnxDestroyOfflineSpeakerDiarization)>(
            SherpaOnnxCreateOfflineSpeakerDiarization(&config), SherpaOnnxDestroyOfflineSpeakerDiarization);
        auto extractor = std::unique_ptr<const SherpaOnnxSpeakerEmbeddingExtractor,
                                        decltype(&SherpaOnnxDestroySpeakerEmbeddingExtractor)>(
            SherpaOnnxCreateSpeakerEmbeddingExtractor(&config.embedding), SherpaOnnxDestroySpeakerEmbeddingExtractor);
        if (!diarizer || !extractor) throw std::runtime_error("Cannot load speaker models");
        std::string line;
        while (std::getline(std::cin, line)) {
            try {
                std::cout << infer(json::parse(line), diarizer.get(), extractor.get()).dump() << std::endl;
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
