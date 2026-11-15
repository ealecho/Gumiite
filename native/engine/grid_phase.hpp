#pragma once

// Queen Mary gives a solid tempo but its phase follows whatever onset is
// strongest, which on a lot of house/techno is the offbeat hat, not the kick.
// Once the period is known, the phase is better decided by the audio: pick the
// offset whose grid lines collect the most low-band onset energy.

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>


namespace grid_phase {

// ~2.5 ms per block, band-limited to roughly the kick range.
struct KickEnvelope {
  std::vector<float> energy;
  std::vector<float> onset; // positive energy rise
  double blockSec = 0.0;

  int index(double t) const {
    if (blockSec <= 0.0) {
      return -1;
    }
    const int i = (int)std::lround(t / blockSec);
    return (i >= 0 && i < (int)energy.size()) ? i : -1;
  }
};

inline KickEnvelope buildKickEnvelope(const float* pcm, int frames, int channels,
                                      double sampleRate) {
  KickEnvelope env;
  if (!pcm || frames <= 0 || channels < 1 || sampleRate <= 0.0) {
    return env;
  }
  // Boxcar decimation doubles as the low-pass and keeps the envelope
  // symmetric, so peaks stay where the transient actually is.
  const int group = std::max(1, (int)std::lround(sampleRate / 400.0));
  const int blocks = frames / group;
  if (blocks < 4) {
    return env;
  }
  env.blockSec = (double)group / sampleRate;
  env.energy.resize((size_t)blocks);
  for (int b = 0; b < blocks; ++b) {
    double acc = 0.0;
    const int start = b * group;
    for (int i = start; i < start + group; ++i) {
      const float* s = pcm + (size_t)i * (size_t)channels;
      acc += channels == 1 ? (double)s[0] : 0.5 * ((double)s[0] + (double)s[1]);
    }
    const double m = acc / (double)group;
    env.energy[(size_t)b] = (float)(m * m);
  }
  env.onset.assign((size_t)blocks, 0.0f);
  for (int b = 1; b < blocks; ++b) {
    const float rise = env.energy[(size_t)b] - env.energy[(size_t)b - 1];
    env.onset[(size_t)b] = rise > 0.0f ? rise : 0.0f;
  }
  return env;
}

// Offset in [0, periodSec) whose grid lines land on the most onset energy.
// Returns a negative value when the envelope carries no usable signal.
inline double bestPhase(const KickEnvelope& env, double periodSec, double durationSec) {
  if (env.onset.empty() || periodSec <= 0.0 || durationSec <= periodSec) {
    return -1.0;
  }
  const int candidates = std::max(1, (int)std::lround(periodSec / env.blockSec));
  const int lines = (int)(durationSec / periodSec);
  if (lines < 4) {
    return -1.0;
  }
  double bestScore = -1.0;
  double best = -1.0;
  for (int c = 0; c < candidates; ++c) {
    const double offset = c * env.blockSec;
    double score = 0.0;
    for (int k = 0; k < lines; ++k) {
      const int i = env.index(offset + (double)k * periodSec);
      if (i < 0) {
        continue;
      }
      // One block either side, so a kick a hair off the line still counts.
      score += env.onset[(size_t)i];
      if (i > 0) {
        score += 0.5 * env.onset[(size_t)i - 1];
      }
      if (i + 1 < (int)env.onset.size()) {
        score += 0.5 * env.onset[(size_t)i + 1];
      }
    }
    if (score > bestScore) {
      bestScore = score;
      best = offset;
    }
  }
  return bestScore > 0.0 ? best : -1.0;
}

// Windows for judging and correcting a grid along the track: 16 bars, hop 8.
inline constexpr int kGridWindowBeats = 64;
inline constexpr int kGridHopBeats = 32;

// Low-band kick energy collected on `beats` grid lines from `firstBeat`, with
// every line moved `shift` envelope blocks (scored like bestPhase).
inline double windowScore(const KickEnvelope& env, double phaseSec, double periodSec, int firstBeat,
                          int beats, int shift) {
  double s = 0.0;
  for (int k = firstBeat; k < firstBeat + beats; ++k) {
    const int i = env.index(phaseSec + (double)k * periodSec);
    if (i < 0) {
      continue;
    }
    const int j = i + shift;
    if (j < 1 || j + 1 >= (int)env.onset.size()) {
      continue;
    }
    s += env.onset[(size_t)j] + 0.5 * (env.onset[(size_t)j - 1] + env.onset[(size_t)j + 1]);
  }
  return s;
}

// How far a constant grid can be trusted: does it hold through the track?
// In 16-bar windows, find where the low-band kick energy best lines up with
// the grid (offset within a quarter beat, scored like bestPhase). A good grid
// gives the same offset everywhere; a wrong BPM drifts, a tempo change jumps.
// Offsets are compared with their median, so a constant offset (the
// kick-attack refinement places lines on the click, a little before the
// thump) does not count against it. Windows without a real kick (breakdowns)
// are skipped. Returns the share of windows within 12 ms of the median
// offset, or -1 with too few windows to judge.
//
// Per-beat kick counting was tried first and could not tell good grids from
// bad on a deep/afro house library: offbeat bass and soft kicks swamp it.
inline double gridConfidence(const KickEnvelope& env, double phaseSec, double periodSec,
                             double durationSec) {
  if (env.onset.empty() || periodSec <= 0.0 || env.blockSec <= 0.0) {
    return -1.0;
  }
  constexpr int kWindowBeats = kGridWindowBeats;
  constexpr int kHopBeats = kGridHopBeats;
  const int reach = std::max(1, (int)std::lround(0.25 * periodSec / env.blockSec));
  const int totalBeats = (int)((durationSec - phaseSec) / periodSec);
  auto score = [&](int firstBeat, int shift) {
    return windowScore(env, phaseSec, periodSec, firstBeat, kWindowBeats, shift);
  };
  struct Window {
    double strength;
    double offsetSec;
    bool atEdge;
  };
  std::vector<Window> windows;
  for (int first = 0; first + kWindowBeats <= totalBeats; first += kHopBeats) {
    double best = -1.0;
    int bestShift = 0;
    for (int shift = -reach; shift <= reach; ++shift) {
      const double s = score(first, shift);
      if (s > best) {
        best = s;
        bestShift = shift;
      }
    }
    windows.push_back({best, bestShift * env.blockSec, std::abs(bestShift) == reach});
  }
  if (windows.size() < 4) {
    return -1.0;
  }
  std::vector<double> strengths;
  for (const Window& w : windows) {
    strengths.push_back(w.strength);
  }
  std::nth_element(strengths.begin(), strengths.begin() + (std::ptrdiff_t)(strengths.size() / 2),
                   strengths.end());
  const double floor = 0.25 * strengths[strengths.size() / 2];
  std::vector<double> offsets;
  for (const Window& w : windows) {
    if (w.strength > floor) {
      offsets.push_back(w.offsetSec);
    }
  }
  if (offsets.size() < 4) {
    return -1.0;
  }
  std::vector<double> sorted = offsets;
  std::nth_element(sorted.begin(), sorted.begin() + (std::ptrdiff_t)(sorted.size() / 2), sorted.end());
  const double median = sorted[sorted.size() / 2];
  int kept = 0;
  int on = 0;
  for (const Window& w : windows) {
    if (!(w.strength > floor)) {
      continue;
    }
    ++kept;
    // A best offset pinned to the search edge means the kicks lie outside
    // a quarter beat of the grid there: that window is off.
    if (!w.atEdge && std::fabs(w.offsetSec - median) <= 0.012) {
      ++on;
    }
  }
  return (double)on / (double)kept;
}

struct GridLine {
  double phaseSec;
  double periodSec;
};

// Correct a constant grid whose BPM is slightly off, from the kick's low-end
// energy (works on soft kicks the click-band fit can't read). Follows the
// grid's offset window by window, each searched near the last so a slow drift
// can grow past a quarter beat without wrapping, fits a weighted line through
// the offsets (refitted without outliers), and turns its slope into a period
// correction. Returns none when there is no clear, steady drift; callers
// still decide whether the corrected grid holds better (gridConfidence).
inline std::optional<GridLine> correctDrift(const KickEnvelope& env, double phaseSec,
                                            double periodSec, double durationSec) {
  if (env.onset.empty() || periodSec <= 0.0 || env.blockSec <= 0.0) {
    return std::nullopt;
  }
  const int totalBeats = (int)((durationSec - phaseSec) / periodSec);
  const int reach = std::max(1, (int)std::lround(0.25 * periodSec / env.blockSec));
  const int track = std::max(1, reach / 2);
  struct Window {
    double centreSec;
    double offsetSec;
    double strength;
  };
  std::vector<int> firsts;
  for (int first = 0; first + kGridWindowBeats <= totalBeats; first += kGridHopBeats) {
    firsts.push_back(first);
  }
  if (firsts.size() < 6) {
    return std::nullopt;
  }
  // Breakdowns carry no kick to follow: judge strength first, at the grid.
  std::vector<double> strength;
  for (int first : firsts) {
    double best = 0.0;
    for (int s = -reach; s <= reach; ++s) {
      best = std::max(best, windowScore(env, phaseSec, periodSec, first, kGridWindowBeats, s));
    }
    strength.push_back(best);
  }
  std::vector<double> sorted = strength;
  std::nth_element(sorted.begin(), sorted.begin() + (std::ptrdiff_t)(sorted.size() / 2), sorted.end());
  const double floor = 0.25 * sorted[sorted.size() / 2];
  std::vector<Window> windows;
  bool started = false;
  int prev = 0;
  for (size_t w = 0; w < firsts.size(); ++w) {
    if (!(strength[w] > floor)) {
      continue;  // keep following from the last window with a kick
    }
    const int lo = started ? prev - track : -reach;
    const int hi = started ? prev + track : reach;
    double best = -1.0;
    int bestShift = prev;
    for (int s = lo; s <= hi; ++s) {
      const double v = windowScore(env, phaseSec, periodSec, firsts[w], kGridWindowBeats, s);
      if (v > best) {
        best = v;
        bestShift = s;
      }
    }
    started = true;
    prev = bestShift;
    const double centre = phaseSec + ((double)firsts[w] + kGridWindowBeats / 2.0) * periodSec;
    windows.push_back({centre, bestShift * env.blockSec, strength[w]});
  }
  if (windows.size() < 6) {
    return std::nullopt;
  }
  // Weighted least squares of offset on time; second pass without the worst
  // fifth and anything over 15 ms off (a tempo change, a fill).
  auto fit = [](const std::vector<Window>& pts, double& a, double& s) {
    double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (const Window& p : pts) {
      sw += p.strength;
      sx += p.strength * p.centreSec;
      sy += p.strength * p.offsetSec;
      sxx += p.strength * p.centreSec * p.centreSec;
      sxy += p.strength * p.centreSec * p.offsetSec;
    }
    const double denom = sw * sxx - sx * sx;
    if (sw <= 0.0 || std::fabs(denom) < 1e-12) return false;
    s = (sw * sxy - sx * sy) / denom;
    a = (sy - s * sx) / sw;
    return true;
  };
  double a = 0.0, slope = 0.0;
  if (!fit(windows, a, slope)) {
    return std::nullopt;
  }
  std::vector<double> res;
  for (const Window& p : windows) res.push_back(std::fabs(p.offsetSec - a - slope * p.centreSec));
  std::vector<double> rs = res;
  std::sort(rs.begin(), rs.end());
  const double cutoff = std::min(rs[rs.size() * 4 / 5], 0.015);
  std::vector<Window> kept;
  for (size_t i = 0; i < windows.size(); ++i) {
    if (res[i] <= cutoff) kept.push_back(windows[i]);
  }
  if (kept.size() >= 6 && !fit(kept, a, slope)) {
    return std::nullopt;
  }
  // Under 10 ms of drift over the whole track is not worth a new tempo.
  if (std::fabs(slope) * durationSec < 0.010) {
    return std::nullopt;
  }
  // Line k sits at phase + k*period + a + slope*t, with t ~ its own time:
  // the same as a grid of period*(1+slope) from phase + a + slope*phase.
  return GridLine{phaseSec + a + slope * phaseSec, periodSec * (1.0 + slope)};
}

// Phrase 0 goes on the first grid line where the track is actually audible.
// Anything cleverer guesses at musical structure and lands on beat 2 or 3,
// which is worse than a predictable start the user can nudge.
inline double firstAudibleLine(const float* pcm, int frames, int channels, double sampleRate,
                               double phaseSec, double periodSec) {
  if (!pcm || frames <= 0 || channels < 1 || sampleRate <= 0.0 || periodSec <= 0.0) {
    return phaseSec;
  }
  const int block = std::max(1, (int)std::lround(sampleRate * 0.02));
  const int blocks = frames / block;
  if (blocks < 8) {
    return phaseSec;
  }
  std::vector<float> rms((size_t)blocks);
  for (int b = 0; b < blocks; ++b) {
    double acc = 0.0;
    const int start = b * block;
    for (int i = start; i < start + block; ++i) {
      const float* s = pcm + (size_t)i * (size_t)channels;
      const double m = channels == 1 ? (double)s[0] : 0.5 * ((double)s[0] + (double)s[1]);
      acc += m * m;
    }
    rms[(size_t)b] = (float)std::sqrt(acc / (double)block);
  }
  std::vector<float> sorted = rms;
  std::nth_element(sorted.begin(), sorted.begin() + (std::ptrdiff_t)(sorted.size() / 2),
                   sorted.end());
  const float thresh = sorted[sorted.size() / 2] * 0.02f;
  if (!(thresh > 0.0f)) {
    return phaseSec;
  }
  int firstLoud = -1;
  for (int b = 0; b + 2 < blocks; ++b) {
    if (rms[(size_t)b] >= thresh && rms[(size_t)b + 1] >= thresh && rms[(size_t)b + 2] >= thresh) {
      firstLoud = b;
      break;
    }
  }
  if (firstLoud <= 0) {
    return phaseSec;
  }
  // Half a block of slack so a beat that opens the track is not skipped.
  const double startSec = (double)firstLoud * ((double)block / sampleRate) - 0.01;
  const double k = std::ceil((startSec - phaseSec) / periodSec);
  return phaseSec + std::max(0.0, k) * periodSec;
}

} // namespace grid_phase
