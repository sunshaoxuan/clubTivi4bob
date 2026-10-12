#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>
#include <cassert>
#include <iostream>
#define min(a,b) BOBTV_WINDOWS_MIN_MACRO_MUST_NOT_EXPAND
#define max(a,b) BOBTV_WINDOWS_MAX_MACRO_MUST_NOT_EXPAND
#include "../../third_party/media_kit_video/windows/software_video_size.h"

int main() {
  for (auto [w, h] : {std::pair<int64_t, int64_t>{3840,2160}, {1920,1080},
                     {1440,1080}, {720,576}, {2160,3840}, {3440,1440},
                     {640,480}, {4096,2160}}) {
    const auto [ow, oh] = BobTvSoftwareVideoSize(w, h);
    assert(ow >= 1 && oh >= 1 && ow <= 1920 && oh <= 1080);
    assert(std::abs(ow / double(oh) - w / double(h)) < .003);
  }
  assert(BobTvSoftwareVideoSize(3840,2160) == std::make_pair(int64_t(1920),int64_t(1080)));
  assert(BobTvSoftwareVideoSize(0,0) == std::make_pair(int64_t(1),int64_t(1)));
  std::cout << "PASS: landscape, 4:3, portrait, ultrawide and 4K aspect ratios\n";
}
