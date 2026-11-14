#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

// 3-band (low / mid / high) waveform columns in the style of rekordbox's PWV6/PWV7
// tags, following rbxport's re-implementation (crates/rbl-analysis/src/wave_creator.rs,
// GPL-2.0-or-later, https://github.com/chrisle/rbxport).
//
// Per millisecond we keep each band's peak; detail columns (150/s) take an
// instant-attack / exponential-release envelope of that, scaled by a per-track gain
// (PWVC). Values are 0..127 per band, interleaved low, mid, high.
namespace wave_bands {

constexpr double kPi = 3.14159265358979323846;
constexpr int kDetailPerSec = 150;
constexpr int kOverviewColumns = 1200;

struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1 = 0, z2 = 0;

  static Biquad make(double sr, double hz, bool highPass) {
    Biquad q;
    const double w0 = 2.0 * kPi * hz / sr;
    const double c = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    if (highPass) {
      q.b0 = (1 + c) / 2 / a0;
      q.b1 = -(1 + c) / a0;
      q.b2 = (1 + c) / 2 / a0;
    } else {
      q.b0 = (1 - c) / 2 / a0;
      q.b1 = (1 - c) / a0;
      q.b2 = (1 - c) / 2 / a0;
    }
    q.a1 = -2 * c / a0;
    q.a2 = (1 - alpha) / a0;
    return q;
  }

  double run(double x) {
    const double y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    return y;
  }
};

class Scanner {
 public:
  Scanner(int sampleRate, uint64_t totalFrames)
      : sr_(std::max(1, sampleRate)),
        low_(Biquad::make(sr_, 300, false)),
        midHp_(Biquad::make(sr_, 250, true)),
        midLp_(Biquad::make(sr_, 1200, false)),
        highHp_(Biquad::make(sr_, 3000, true)),
        highLp_(Biquad::make(sr_, std::min(9000.0, sr_ * 0.45), false)) {
    const uint64_t ms = totalFrames * 1000 / (uint64_t)sr_ + 1;
    for (auto& p : peaks_) p.reserve((size_t)ms);
    nextMsStart_ = msStart(1);
  }

  void push(float left, float right) {
    const double l = left, r = right;
    // Out-of-phase channels would cancel in a plain mean; take the louder one then.
    const double mono = std::fabs(std::fabs(l) - std::fabs(r)) >= 0.001
                            ? 0.5 * (l + r)
                            : (std::fabs(l) > std::fabs(r) ? l : r);
    const double lo = std::fabs(low_.run(mono));
    const double mid = std::fabs(midLp_.run(midHp_.run(mono)));
    const double hi = std::fabs(highLp_.run(highHp_.run(mono)));
    cur_[0] = std::max(cur_[0], lo);
    cur_[1] = std::max(cur_[1], mid);
    cur_[2] = std::max(cur_[2], hi);
    if (++frame_ >= nextMsStart_) closeMs();
  }

  /** Detail columns (kDetailPerSec per second) and kOverviewColumns overview columns. */
  void finish(std::vector<uint8_t>& detail, std::vector<uint8_t>& overview) {
    if (cur_[0] > 0 || cur_[1] > 0 || cur_[2] > 0) closeMs();
    const size_t ms = peaks_[0].size();
    detail.clear();
    overview.assign((size_t)kOverviewColumns * 3, 0);
    if (ms == 0) return;

    // Overview means per band, then PWVC gains from them.
    std::vector<double> mean[3];
    for (int b = 0; b < 3; ++b) mean[b].assign(kOverviewColumns, 0.0);
    for (int c = 0; c < kOverviewColumns; ++c) {
      const size_t m0 = ms * (size_t)c / kOverviewColumns;
      const size_t m1 = std::max(m0 + 1, ms * (size_t)(c + 1) / kOverviewColumns);
      for (int b = 0; b < 3; ++b) {
        double s = 0;
        for (size_t m = m0; m < m1 && m < ms; ++m) s += peaks_[b][m];
        mean[b][(size_t)c] = s / (double)(m1 - m0);
      }
    }
    double sum[3] = {0, 0, 0}, peak[3] = {0, 0, 0};
    for (int b = 0; b < 3; ++b) {
      for (double v : mean[b]) sum[b] += v;
      for (double v : peaks_[b]) peak[b] = std::max(peak[b], v);
    }
    const double largest = std::max({sum[0], sum[1], sum[2]});
    double equal[3];
    for (int b = 0; b < 3; ++b) equal[b] = sum[b] > 0 ? largest / sum[b] : 0;
    double tallest = 0;
    for (int c = 0; c < kOverviewColumns; ++c) {
      double t = 0;
      for (int b = 0; b < 3; ++b) t += equal[b] * mean[b][(size_t)c];
      tallest = std::max(tallest, t);
    }
    constexpr double kCap[3] = {3, 3, 5};
    double raw[3], gain[3];
    for (int b = 0; b < 3; ++b) {
      raw[b] = tallest > 0 ? kFull * equal[b] / tallest : 0;
      double held = raw[b];
      if (peak[b] > 0) {
        const double limit = b < 2 ? kFull / peak[b]
                                   : kFull / (16384.0 * (1 - std::cos(kPi * peak[b] / kFull)));
        held = std::min(held, limit);
      }
      gain[b] = held < 0.8 ? 0.8 : std::min(held, kCap[b]);
    }
    for (int c = 0; c < kOverviewColumns; ++c) {
      for (int b = 0; b < 3; ++b) {
        const double v = mean[b][(size_t)c] * std::clamp(raw[b], 0.8, kCap[b]) / 256.0;
        overview[(size_t)c * 3 + b] = clamp127(v);
      }
    }

    // Detail: running envelope over the per-ms peaks, sampled at each column's last ms.
    constexpr double kDecay[3] = {0.99, 0.98, 0.97};
    const size_t cols = std::max<size_t>(1, ms * kDetailPerSec / 1000);
    detail.assign(cols * 3, 0);
    double held[3] = {0, 0, 0};
    size_t m = 0;
    for (size_t c = 0; c < cols; ++c) {
      const size_t at = std::min(ms - 1, (c + 1) * 1000 / kDetailPerSec);
      for (; m <= at; ++m) {
        for (int b = 0; b < 3; ++b) {
          const double v = peaks_[b][m];
          held[b] = v > held[b] ? v : v + (held[b] - v) * kDecay[b];
        }
      }
      detail[c * 3 + 0] = clamp127(held[0] * gain[0] / 256.0);
      detail[c * 3 + 1] = clamp127(held[1] * gain[1] / 256.0);
      detail[c * 3 + 2] = clamp127(gain[2] * 64.0 * (1 - std::cos(kPi * held[2] / kFull)));
    }
  }

 private:
  static constexpr double kFull = 32768.0;

  static uint8_t clamp127(double v) { return (uint8_t)std::clamp(v, 0.0, 127.0); }

  uint64_t msStart(uint64_t i) const { return (i * (uint64_t)sr_ + 999) / 1000; }

  void closeMs() {
    for (int b = 0; b < 3; ++b) {
      peaks_[b].push_back((float)std::min(kFull, cur_[b] * kFull));
      cur_[b] = 0;
    }
    nextMsStart_ = msStart(peaks_[0].size() + 1);
  }

  int sr_;
  Biquad low_, midHp_, midLp_, highHp_, highLp_;
  std::vector<float> peaks_[3];
  double cur_[3] = {0, 0, 0};
  uint64_t frame_ = 0;
  uint64_t nextMsStart_ = 0;
};

}  // namespace wave_bands
