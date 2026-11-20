#define INITGUID
#include <windows.h>
#include <sapi.h>

#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

template<class T> struct Com {
    T* value = nullptr;
    ~Com() { if (value) value->Release(); }
    T* operator->() const { return value; }
};

static constexpr unsigned bytesPerSecond = 32000;

static std::string jsonText(const wchar_t* value) {
    if (!value) return {};
    const auto length = std::wcslen(value);
    if (!length || length > 200) return {};
    char utf8[800];
    const int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value,
                                      int(length), utf8, sizeof utf8, nullptr, nullptr);
    std::string escaped;
    for (int i = 0; i < n; ++i) {
        const unsigned char c = utf8[i];
        if (c < 0x20) return {};
        if (c == '"' || c == '\\') escaped += '\\';
        escaped += char(c);
    }
    return escaped;
}

static void appendWords(ISpRecoResult* result, LANGID language, double duration,
                        std::ostringstream& output, unsigned& count) {
    SPPHRASE* raw = nullptr;
    if (!result || FAILED(result->GetPhrase(&raw)) || !raw) return;
    const std::unique_ptr<SPPHRASE, decltype(&CoTaskMemFree)> phrase(raw, CoTaskMemFree);
    if (raw->LangID != language || !raw->pElements || raw->Rule.ulCountOfElements > 512) return;
    for (ULONG i = 0; i < raw->Rule.ulCountOfElements && count < 512; ++i) {
        const auto& item = raw->pElements[i];
        if (item.ActualConfidence < SP_NORMAL_CONFIDENCE || !item.ulAudioSizeBytes) continue;
        const double start = raw->ullAudioStreamPosition / double(bytesPerSecond)
                           + item.ulAudioStreamOffset / double(bytesPerSecond);
        const double stop = start + item.ulAudioSizeBytes / double(bytesPerSecond);
        const auto word = jsonText(item.pszLexicalForm);
        if (word.empty() || start >= duration || stop > duration + 0.1) continue;
        if (count++) output << ',';
        output << "{\"word\":\"" << word << "\",\"start\":" << start
               << ",\"end\":" << std::min(stop, duration) << ",\"probability\":"
               << (item.ActualConfidence == SP_HIGH_CONFIDENCE ? .9 : .68) << '}';
    }
}

static void recognize(const wchar_t* path, const wchar_t* locale) {
    const auto lcid = LocaleNameToLCID(locale, 0);
    if (!lcid) return;
    const auto language = LANGIDFROMLCID(lcid);
    // Require a Microsoft-installed recognizer for the requested locale.
    // Never choose a shared recognizer or call SetInput with a null stream.
    Com<ISpObjectTokenCategory> category;
    Com<IEnumSpObjectTokens> tokens;
    wchar_t attributes[64];
    swprintf(attributes, 64, L"Vendor=Microsoft;Language=%x", unsigned(language));
    if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_INPROC_SERVER,
                                IID_ISpObjectTokenCategory, (void**)&category.value)) ||
        FAILED(category->SetId(SPCAT_RECOGNIZERS, FALSE)) ||
        FAILED(category->EnumTokens(attributes, nullptr, &tokens.value))) return;
    Com<ISpObjectToken> token;
    if (tokens->Next(1, &token.value, nullptr) != S_OK) return;

    std::ifstream input(path, std::ios::binary | std::ios::ate);
    const auto size = input.tellg();
    if (size < 3200 || size > 40 * bytesPerSecond || size % 2) return;
    std::vector<char> pcm(static_cast<size_t>(size));
    if (!input.seekg(0).read(pcm.data(), size)) return;
    Com<IStream> memory;
    Com<ISpStream> stream;
    WAVEFORMATEX format{WAVE_FORMAT_PCM, 1, 16000, bytesPerSecond, 2, 16, 0};
    const GUID waveFormat = {0xc31adbae, 0x527f, 0x4ff5, {0xa2,0x30,0xf6,0x2b,0xb6,0x1f,0xf7,0x0c}};
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &memory.value)) ||
        FAILED(memory->Write(pcm.data(), static_cast<ULONG>(size), nullptr)) ||
        FAILED(memory->Seek({}, STREAM_SEEK_SET, nullptr)) ||
        FAILED(CoCreateInstance(CLSID_SpStream, nullptr, CLSCTX_INPROC_SERVER,
                                IID_ISpStream, (void**)&stream.value)) ||
        FAILED(stream->SetBaseStream(memory.value, waveFormat, &format))) return;

    Com<ISpRecognizer> recognizer;
    Com<ISpRecoContext> context;
    Com<ISpRecoGrammar> grammar;
    const auto interests = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_END_SR_STREAM);
    if (FAILED(CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_INPROC_SERVER,
                                IID_ISpRecognizer, (void**)&recognizer.value)) ||
        FAILED(recognizer->SetRecognizer(token.value)) ||
        FAILED(recognizer->SetInput(stream.value, TRUE)) ||
        FAILED(recognizer->CreateRecoContext(&context.value)) ||
        FAILED(context->SetNotifyWin32Event()) ||
        FAILED(context->SetInterest(interests, interests)) ||
        FAILED(context->CreateGrammar(1, &grammar.value)) ||
        FAILED(grammar->LoadDictation(nullptr, SPLO_STATIC)) ||
        FAILED(grammar->SetDictationState(SPRS_ACTIVE))) return;

    bool ended = false;
    unsigned count = 0;
    std::ostringstream output;
    output << "{\"words\":[";
    const auto deadline = GetTickCount64() + 2400;
    while (!ended && GetTickCount64() < deadline) {
        if (context->WaitForNotifyEvent(100) != S_OK) continue;
        SPEVENT event{};
        while (context->GetEvents(1, &event, nullptr) == S_OK) {
            if (event.eEventId == SPEI_RECOGNITION && event.elParamType == SPET_LPARAM_IS_OBJECT)
                appendWords(reinterpret_cast<ISpRecoResult*>(event.lParam), language,
                            double(size) / bytesPerSecond, output, count);
            if (event.eEventId == SPEI_END_SR_STREAM) ended = true;
            if (event.elParamType == SPET_LPARAM_IS_OBJECT || event.elParamType == SPET_LPARAM_IS_TOKEN) {
                if (event.lParam) reinterpret_cast<IUnknown*>(event.lParam)->Release();
            } else if (event.elParamType == SPET_LPARAM_IS_POINTER || event.elParamType == SPET_LPARAM_IS_STRING) {
                CoTaskMemFree(reinterpret_cast<void*>(event.lParam));
            }
        }
    }
    if (ended && count) {
        output << "]}";
        std::fputs(output.str().c_str(), stdout);
    }
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3 || FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 0;
    recognize(argv[1], argv[2]);
    CoUninitialize();
    return 0;
}
