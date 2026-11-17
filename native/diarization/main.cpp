// Local-only sherpa-onnx C API adapter. Outputs cluster intervals, never identities.
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include "sherpa-onnx/c-api/c-api.h"

int main(int argc, char **argv) {
  if (argc != 6 && argc != 7) {
    std::cerr << "Usage: vtracker-diarize SEGMENTATION.onnx EMBEDDING.onnx INPUT.wav OUTPUT.json SPEAKERS(0=auto) [CLUSTER_THRESHOLD]\n";
    return 2;
  }
  try {
    size_t consumed = 0;
    int speakers = std::stoi(argv[5], &consumed);
    if (argv[5][consumed] != '\0' || speakers < 0 || speakers > 64) throw std::runtime_error("Invalid speaker count");
    SherpaOnnxOfflineSpeakerDiarizationConfig config{};
    config.segmentation.pyannote.model = argv[1];
    config.segmentation.pyannote.window_shift_ratio = 0.2f;
    config.segmentation.num_threads = 4;
    config.segmentation.provider = "cpu";
    config.embedding.model = argv[2];
    config.embedding.num_threads = 4;
    config.embedding.provider = "cpu";
    config.clustering.num_clusters = speakers;
    float threshold = 0.5f;
    if (argc == 7) {
      threshold = std::stof(argv[6], &consumed);
      if (argv[6][consumed] != '\0' || !std::isfinite(threshold) || threshold <= 0 || threshold > 1)
        throw std::runtime_error("Invalid clustering threshold");
    }
    config.clustering.threshold = threshold;
    config.min_duration_on = 0.2f;
    config.min_duration_off = 0.5f;
    auto sd = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarization, decltype(&SherpaOnnxDestroyOfflineSpeakerDiarization)>(
        SherpaOnnxCreateOfflineSpeakerDiarization(&config), SherpaOnnxDestroyOfflineSpeakerDiarization);
    if (!sd) throw std::runtime_error("Cannot initialize diarization models");
    auto wave = std::unique_ptr<const SherpaOnnxWave, decltype(&SherpaOnnxFreeWave)>(SherpaOnnxReadWave(argv[3]), SherpaOnnxFreeWave);
    if (!wave || wave->num_samples <= 0 || wave->sample_rate != SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd.get()))
      throw std::runtime_error("Expected non-empty mono WAV at the model sample rate");
    auto result = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationResult, decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroyResult)>(
        SherpaOnnxOfflineSpeakerDiarizationProcess(sd.get(), wave->samples, wave->num_samples), SherpaOnnxOfflineSpeakerDiarizationDestroyResult);
    if (!result) throw std::runtime_error("Diarization failed");
    int count = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result.get());
    auto turns = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationSegment, decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroySegment)>(
        SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result.get()), SherpaOnnxOfflineSpeakerDiarizationDestroySegment);
    if (count < 0 || (count > 0 && !turns)) throw std::runtime_error("Invalid diarization result");
    std::ofstream output(argv[4]);
    if (!output) throw std::runtime_error("Cannot open output file");
    output << "{\"window_shift_ratio\":" << config.segmentation.pyannote.window_shift_ratio
           << ",\"turns\":[";
    for (int i = 0; i < count; ++i) {
      const auto &s = turns.get()[i];
      if (!std::isfinite(s.start) || !std::isfinite(s.end) || s.start < 0 || s.end <= s.start || s.speaker < 0)
        throw std::runtime_error("Invalid diarization interval");
      if (i) output << ',';
      output << "{\"start_ms\":" << std::llround(s.start*1000) << ",\"end_ms\":" << std::llround(s.end*1000)
             << ",\"speaker\":" << s.speaker << '}';
    }
    output << "]}\n";
    output.close();
    if (!output) throw std::runtime_error("Cannot finish output file");
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
