// Local speaker embedding adapter. No names or identity decisions leave this process.
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include "sherpa-onnx/c-api/c-api.h"
int main(int argc, char **argv) {
  if(argc!=4) {std::cerr<<"Usage: vtracker-embed MODEL.onnx INPUT.wav OUTPUT.json\n";return 2;}
  try {
    SherpaOnnxSpeakerEmbeddingExtractorConfig config{};
    config.model=argv[1];config.num_threads=2;config.provider="cpu";
    auto ex=std::unique_ptr<const SherpaOnnxSpeakerEmbeddingExtractor,decltype(&SherpaOnnxDestroySpeakerEmbeddingExtractor)>(SherpaOnnxCreateSpeakerEmbeddingExtractor(&config),SherpaOnnxDestroySpeakerEmbeddingExtractor);
    if(!ex) throw std::runtime_error("Cannot initialize embedding model");
    auto wave=std::unique_ptr<const SherpaOnnxWave,decltype(&SherpaOnnxFreeWave)>(SherpaOnnxReadWave(argv[2]),SherpaOnnxFreeWave);
    if(!wave || wave->sample_rate!=16000 || wave->num_samples<64000 || wave->num_samples>960000) throw std::runtime_error("Expected 4..60 seconds of mono 16 kHz WAV");
    auto stream=std::unique_ptr<const SherpaOnnxOnlineStream,decltype(&SherpaOnnxDestroyOnlineStream)>(SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex.get()),SherpaOnnxDestroyOnlineStream);
    if(!stream) throw std::runtime_error("Cannot initialize embedding stream");
    SherpaOnnxOnlineStreamAcceptWaveform(stream.get(),16000,wave->samples,wave->num_samples);
    SherpaOnnxOnlineStreamInputFinished(stream.get());
    if(!SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex.get(),stream.get())) throw std::runtime_error("Insufficient audio for embedding");
    const int dim=SherpaOnnxSpeakerEmbeddingExtractorDim(ex.get());
    auto values=std::unique_ptr<const float,decltype(&SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding)>(SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex.get(),stream.get()),SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);
    if(!values || dim<=0 || dim>4096) throw std::runtime_error("Invalid embedding result");
    std::ofstream out(argv[3]);out<<std::setprecision(9)<<"{\"embedding\":[";
    for(int i=0;i<dim;++i) {if(!std::isfinite(values.get()[i])) throw std::runtime_error("Non-finite embedding");if(i)out<<',';out<<values.get()[i];}
    out<<"]}\n";out.close();if(!out)throw std::runtime_error("Cannot save embedding");
    return 0;
  } catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;}
}
