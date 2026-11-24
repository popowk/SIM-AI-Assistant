// Persistent local speech recognizer. Input protocol:
// 0x00 + 640 bytes PCM16 LE at 16 kHz; 0x01 resets the stream.
// stdout READY / TEXT <UTF-8> only. Never writes telephone audio to disk.
#include "c-api.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <cstdint>

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    const std::string root = argv[1];
    const std::string enc = root + "/encoder-epoch-99-avg-1.int8.onnx";
    const std::string dec = root + "/decoder-epoch-99-avg-1.int8.onnx";
    const std::string join = root + "/joiner-epoch-99-avg-1.int8.onnx";
    const std::string tokens = root + "/tokens.txt";
    SherpaOnnxOnlineRecognizerConfig config{};
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = enc.c_str();
    config.model_config.transducer.decoder = dec.c_str();
    config.model_config.transducer.joiner = join.c_str();
    config.model_config.tokens = tokens.c_str();
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = 2.4f;
    config.rule2_min_trailing_silence = 0.8f;
    config.rule3_min_utterance_length = 14.0f;
    const auto *rec = SherpaOnnxCreateOnlineRecognizer(&config);
    if (!rec) return 65;
    const auto *stream = SherpaOnnxCreateOnlineStream(rec);
    if (!stream) { SherpaOnnxDestroyOnlineRecognizer(rec); return 66; }
    std::puts("SIMAI_READY"); std::fflush(stdout);
    unsigned char bytes[640];
    float samples[320];
    int cmd;
    while ((cmd = std::getchar()) != EOF) {
        if (cmd == 1) { SherpaOnnxOnlineStreamReset(rec, stream); continue; }
        if (cmd != 0 || std::fread(bytes, 1, 640, stdin) != 640) break;
        for (size_t i = 0; i < 320; ++i) {
            uint16_t bits = uint16_t(bytes[i * 2]) | (uint16_t(bytes[i * 2 + 1]) << 8);
            int32_t value = bits < 32768 ? int32_t(bits) : int32_t(bits) - 65536;
            samples[i] = float(value) / 32768.0f;
        }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, 320);
        while (SherpaOnnxIsOnlineStreamReady(rec, stream)) SherpaOnnxDecodeOnlineStream(rec, stream);
        if (SherpaOnnxOnlineStreamIsEndpoint(rec, stream)) {
            const auto *result = SherpaOnnxGetOnlineStreamResult(rec, stream);
            if (result && result->text && result->text[0]) {
                std::string text(result->text);
                for (auto &ch : text) if (ch == '\r' || ch == '\n') ch = ' ';
                std::printf("SIMAI_TEXT %s\n", text.c_str()); std::fflush(stdout);
            }
            if (result) SherpaOnnxDestroyOnlineRecognizerResult(result);
            SherpaOnnxOnlineStreamReset(rec, stream);
        }
    }
    SherpaOnnxDestroyOnlineStream(stream);
    SherpaOnnxDestroyOnlineRecognizer(rec);
    return 0;
}
