#pragma once

// Fine grid placement after rbxport (https://github.com/chrisle/rbxport,
// GPL-2.0-or-later): crates/rbl-analysis/src/attack.rs and tempo.rs
// (snap_and_fit, whole_bpm, on_line).
//
// The coarse grid (Queen Mary period + kick-energy phase) is within a few
// milliseconds of the music. Here every predicted beat is snapped to the
// nearest kick attack found to the millisecond in the 900-9000 Hz click band,
// and a weighted line through those hits gives the period and phase. A whole
// BPM is only taken when its line still sits on the hits, so a real 127.97
// track is not rounded into drift.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <vector>


namespace grid_fit {

struct Attack {
  double secs;
  double height;
};

// The track band-passed to the click band, kept only as RMS per millisecond
// (the band-passed audio itself is never stored).
class AttackMap {
 public:
  AttackMap(const float* pcm, int frames, int channels, double sampleRate) {
    if (!pcm || frames <= 0 || channels < 1 || sampleRate <= 0.0) {
      return;
    }
    sr_ = sampleRate;
    step_ = std::max(1, (int)(0.001 * sampleRate));
    const double nyquist = sampleRate / 2.0;
    Biquad hp = Biquad::make(std::clamp(900.0, 1.0, nyquist * 0.99), sampleRate, true);
    Biquad lp = Biquad::make(std::clamp(9000.0, 1.0, nyquist * 0.99), sampleRate, false);
    rms_.reserve((size_t)(frames / step_) + 1);
    double acc = 0.0;
    int n = 0;
    for (int i = 0; i < frames; ++i) {
      const float* s = pcm + (size_t)i * (size_t)channels;
      const double x = channels == 1 ? (double)s[0] : 0.5 * ((double)s[0] + (double)s[1]);
      const double y = lp.run(hp.run(x));
      acc += y * y;
      if (++n == step_) {
        rms_.push_back((float)std::sqrt(acc / n));
        acc = 0.0;
        n = 0;
      }
    }
    if (n > 0) {
      rms_.push_back((float)std::sqrt(acc / n));
    }
  }

  // The attack nearest `secs` within `reach` either side, or none where the
  // band does not spike (a breakdown, a beatless intro).
  std::optional<Attack> near(double secs, double reach = 0.015) const {
    if (rms_.size() < 3 || sr_ <= 0.0) {
      return std::nullopt;
    }
    const double stepSecs = (double)step_ / sr_;
    const long centre = std::max(0L, std::lround(secs / stepSecs));
    const long r = std::max(1L, (long)std::ceil(reach / stepSecs));
    const long lo = std::max(1L, centre - r);
    const long hi = std::min((long)rms_.size() - 1, centre + r);
    if (hi <= lo) {
      return std::nullopt;
    }
    auto rise = [&](long i) { return (double)rms_[(size_t)i] - (double)rms_[(size_t)i - 1]; };
    double steepest = 0.0;
    long at = lo;
    for (long i = lo; i <= hi; ++i) {
      if (rise(i) > steepest) {
        steepest = rise(i);
        at = i;
      }
    }
    if (steepest <= 0.0) {
      return std::nullopt;
    }
    // Must stand well above the window's ordinary step-to-step wobble.
    std::vector<double> rises;
    for (long i = lo; i <= hi; ++i) {
      rises.push_back(std::fabs(rise(i)));
    }
    std::nth_element(rises.begin(), rises.begin() + (std::ptrdiff_t)(rises.size() / 2), rises.end());
    if (steepest < rises[rises.size() / 2] * kMinSpikeOverWobble) {
      return std::nullopt;
    }
    // Of the rises at least half as steep as the steepest, the nearest wins:
    // taking the steepest outright lets a late-slipping grid chase hits away.
    long chosen = at;
    double chosenRise = steepest;
    for (long i = lo; i <= hi; ++i) {
      if (rise(i) >= steepest * kNearestStrong && std::labs(i - centre) < std::labs(chosen - centre)) {
        chosen = i;
        chosenRise = rise(i);
      }
    }
    // Walk back to where the run of rises into the spike starts.
    long start = chosen;
    while (start > lo && rise(start - 1) > chosenRise * kRunFraction) {
      --start;
    }
    const double floor = rms_[(size_t)start - 1];
    double top = floor;
    for (long i = start; i <= hi; ++i) {
      top = std::max(top, (double)rms_[(size_t)i]);
    }
    // Midpoint of the bin before the rise: avoids a half-bin early bias.
    const double sample = (double)(start - 1) * step_ + step_ / 2.0;
    return Attack{sample / sr_, top - floor};
  }

  bool empty() const { return rms_.size() < 3; }

 private:
  static constexpr double kMinSpikeOverWobble = 4.0;
  static constexpr double kRunFraction = 0.1;
  static constexpr double kNearestStrong = 0.5;

  struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    // RBJ cookbook, with rbxport's alpha = sin(w) / (2 * sqrt 2).
    static Biquad make(double hz, double sr, bool highPass) {
      const double w = 2.0 * 3.14159265358979323846 * hz / sr;
      const double alpha = std::sin(w) / (2.0 * std::sqrt(2.0));
      const double c = std::cos(w);
      const double a0 = 1.0 + alpha;
      Biquad q;
      if (highPass) {
        q.b0 = (1.0 + c) / 2.0 / a0;
        q.b1 = -(1.0 + c) / a0;
      } else {
        q.b0 = (1.0 - c) / 2.0 / a0;
        q.b1 = (1.0 - c) / a0;
      }
      q.b2 = q.b0;
      q.a1 = -2.0 * c / a0;
      q.a2 = (1.0 - alpha) / a0;
      return q;
    }

    double run(double x) {
      const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      return y;
    }
  };

  std::vector<float> rms_;
  int step_ = 1;
  double sr_ = 0.0;
};

// A grid line: beat k sits at phase + k * period (seconds).
struct Fit {
  double phase = 0.0;
  double period = 0.0;
};

// Snap each predicted beat in [0, duration) to its attack and fit a weighted
// line through the hits, twice, the second time without the worst fifth and
// anything over a tenth of a beat off. With `fixedPeriod`, only the phase is
// fitted. Returns the fit and its support (summed hit strength), or none when
// there are too few hits or the fit walks away from the candidate period.
inline std::optional<std::pair<Fit, double>> snapAndFit(const AttackMap& map, Fit current,
                                                        double duration,
                                                        std::optional<double> fixedPeriod = {}) {
  const double period = current.period;
  if (period <= 0.0 || map.empty()) {
    return std::nullopt;
  }
  struct Hit {
    double k, t, w;
  };
  const long first = (long)std::ceil((0.0 - current.phase) / period);
  const long last = (long)std::floor((duration - current.phase) / period);
  if (last < first + 4) {
    return std::nullopt;
  }
  std::vector<Hit> hits;
  for (long k = first; k <= last; ++k) {
    if (auto a = map.near(current.phase + (double)k * period)) {
      hits.push_back({(double)k, a->secs, a->height});
    }
  }
  if (hits.size() < 4) {
    return std::nullopt;
  }
  // Leave out near-silent beats entirely: a minute of pad-intro noise peaks
  // would otherwise tilt a line extrapolated back over that same minute.
  {
    std::vector<double> h;
    for (const Hit& x : hits) h.push_back(x.w);
    std::nth_element(h.begin(), h.begin() + (std::ptrdiff_t)(h.size() / 2), h.end());
    const double floor = h[h.size() / 2] * 0.2;
    std::vector<Hit> strong;
    for (const Hit& x : hits) {
      if (x.w >= floor) strong.push_back(x);
    }
    if (strong.size() >= 4) hits.swap(strong);
  }
  auto line = [&](const std::vector<Hit>& pts) -> std::optional<Fit> {
    double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (const Hit& p : pts) {
      sw += p.w;
      sx += p.w * p.k;
      sy += p.w * p.t;
      sxx += p.w * p.k * p.k;
      sxy += p.w * p.k * p.t;
    }
    if (sw <= 0.0) return std::nullopt;
    if (fixedPeriod) return Fit{(sy - *fixedPeriod * sx) / sw, *fixedPeriod};
    const double denom = sw * sxx - sx * sx;
    if (std::fabs(denom) < 1e-12) return std::nullopt;
    const double slope = (sw * sxy - sx * sy) / denom;
    return Fit{(sy - slope * sx) / sw, slope};
  };
  auto f = line(hits);
  if (!f) return std::nullopt;
  std::vector<double> res;
  for (const Hit& p : hits) res.push_back(std::fabs(p.t - f->phase - f->period * p.k));
  std::vector<double> sorted = res;
  std::sort(sorted.begin(), sorted.end());
  const double cutoff = std::min(sorted[sorted.size() * 4 / 5], period * 0.1);
  std::vector<Hit> kept;
  for (size_t i = 0; i < hits.size(); ++i) {
    if (res[i] <= cutoff) kept.push_back(hits[i]);
  }
  if (kept.size() >= 4) {
    if (auto g = line(kept)) f = g;
  } else {
    kept = hits;
  }
  if (std::fabs(f->period - period) > period * 0.02) {
    return std::nullopt;
  }
  double support = 0.0;
  for (const Hit& p : kept) support += p.w;
  return std::make_pair(*f, support);
}

// How much of the music a line sits on: each beat's attack strength, in full
// on the line and less the further off, down to nothing at 10 ms.
inline double onLine(const AttackMap& map, Fit f, double duration) {
  if (f.period <= 0.0) return 0.0;
  const long first = (long)std::ceil((0.0 - f.phase) / f.period);
  const long last = (long)std::floor((duration - f.phase) / f.period);
  double sum = 0.0;
  for (long k = first; k <= last; ++k) {
    const double predicted = f.phase + (double)k * f.period;
    if (auto a = map.near(predicted)) {
      sum += a->height * std::max(0.0, 1.0 - std::fabs(a->secs - predicted) / 0.010);
    }
  }
  return sum;
}

// How tightly a line sits on the click-band attacks: the share of beats with
// an attack within 15 ms, and the median distance of those attacks (ms).
struct Lock {
  double hitShare = 0.0;
  double medianMs = 1e9;
};

inline Lock lockOf(const AttackMap& map, Fit f, double duration) {
  Lock out;
  if (f.period <= 0.0 || map.empty()) return out;
  const long first = (long)std::ceil((0.0 - f.phase) / f.period);
  const long last = (long)std::floor((duration - f.phase) / f.period);
  int beats = 0;
  std::vector<double> res;
  for (long k = first; k <= last; ++k) {
    const double predicted = f.phase + (double)k * f.period;
    ++beats;
    if (auto a = map.near(predicted, 0.015)) {
      res.push_back(std::fabs(a->secs - predicted) * 1000.0);
    }
  }
  if (beats == 0 || res.empty()) return out;
  out.hitShare = (double)res.size() / (double)beats;
  std::nth_element(res.begin(), res.begin() + (std::ptrdiff_t)(res.size() / 2), res.end());
  out.medianMs = res[res.size() / 2];
  return out;
}

// The click band only describes kicks that have a click. Measured on a deep /
// afro house library, locked fits had 53-92% of beats on an attack with a
// 0.3-1.9 ms median; soft, round kicks gave 13-36% at 2-6 ms, i.e. the fit
// was reading hats and shakers. Only a fit this tight replaces the coarse
// (low-band kick energy) grid.
inline constexpr double kLockMinHitShare = 0.45;
inline constexpr double kLockMaxMedianMs = 2.0;

struct Refined {
  std::optional<Fit> fit;  // none: keep the coarse grid
  Lock lock;               // of the fit, when there was one
};

// Refine a coarse grid against the kick attacks. With `fixedPeriod` (a tag
// BPM) only the phase moves. Otherwise the period is measured too and a whole
// BPM within 0.1 is taken only while its line keeps >= 85% of the measured
// line's hits. No fit when the audio gives too little to go on.
inline Refined refine(const float* pcm, int frames, int channels, double sampleRate, Fit coarse,
                      bool fixedPeriod) {
  Refined out;
  if (frames <= 0 || sampleRate <= 0.0 || coarse.period <= 0.0) return out;
  const double duration = (double)frames / sampleRate;
  const AttackMap map(pcm, frames, channels, sampleRate);
  if (map.empty()) return out;
  const std::optional<double> fixed =
      fixedPeriod ? std::optional<double>(coarse.period) : std::nullopt;
  auto finish = [&](std::optional<Fit> f) {
    if (f) {
      out.lock = lockOf(map, *f, duration);
      if (out.lock.hitShare < kLockMinHitShare || out.lock.medianMs > kLockMaxMedianMs) {
        f.reset();  // not locked onto kicks: keep the coarse grid
      }
    }
    out.fit = f;
    return out;
  };

  // A few snap-and-refit passes: each lands the predictions closer to the
  // hits they snap to.
  Fit fit = coarse;
  bool any = false;
  for (int pass = 0; pass < 3; ++pass) {
    auto next = snapAndFit(map, fit, duration, fixed);
    if (!next) break;
    fit = next->first;
    any = true;
  }
  if (!any) return finish(std::nullopt);
  if (fixedPeriod) return finish(fit);

  constexpr double kWholeBpmTolerance = 0.1;
  constexpr double kWholeBpmSupport = 0.85;
  const double bpm = 60.0 / fit.period;
  const double whole = std::round(bpm);
  if (whole <= 0.0 || std::fabs(bpm - whole) > kWholeBpmTolerance) return finish(fit);
  const Fit start{fit.phase, 60.0 / whole};
  auto snapped = snapAndFit(map, start, duration, start.period);
  const Fit candidate = snapped ? snapped->first : start;
  if (onLine(map, candidate, duration) < onLine(map, fit, duration) * kWholeBpmSupport) {
    return finish(fit);
  }
  return finish(candidate);
}

}  // namespace grid_fit
