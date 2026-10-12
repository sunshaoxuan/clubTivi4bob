#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>

// Fit the complete frame into the software-rendering budget with one scale.
inline std::pair<int64_t, int64_t> BobTvSoftwareVideoSize(
    int64_t width, int64_t height, int64_t max_width = 1920,
    int64_t max_height = 1080) {
  if (width <= 0 || height <= 0) return {1, 1};
  const auto scale = (std::min)({1.0, max_width / double(width),
                              max_height / double(height)});
  return {(std::max<int64_t>)(1, std::llround(width * scale)),
          (std::max<int64_t>)(1, std::llround(height * scale))};
}
