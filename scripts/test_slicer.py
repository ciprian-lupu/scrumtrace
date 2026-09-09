#!/usr/bin/env python3
"""MeetingSlicer merge must not produce working windows longer than clipMaxDuration (25s)."""

from __future__ import annotations


CLIP_MAX = 25.0
CLIP_MEAN = 20.0


def clamp_window(center: float, duration: float, media_duration: float) -> tuple[float, float]:
    half = duration / 2
    start = max(0.0, center - half)
    end = min(media_duration, start + duration)
    start = max(0.0, end - duration)
    if end <= start:
        end = min(media_duration, start + 1)
    return start, end


def union_stills(lhs: list[str], rhs: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for path in lhs + rhs:
        if not path or path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out


def merge_overlapping(
    windows: list[tuple[float, float, float, list[str]]],
    media_duration: float,
) -> list[tuple[float, float, float, list[str]]]:
    """(start, end, score, stills) sorted by start. Overlap expands unless over CLIP_MAX."""
    ordered = sorted(windows, key=lambda item: item[0])
    result: list[tuple[float, float, float, list[str]]] = []
    for start, end, score, stills in ordered:
        if result and result[-1][0] < end and start < result[-1][1]:
            ls, le, lscore, lstills = result[-1]
            prefer_score = max(lscore, score)
            merged_stills = union_stills(lstills, stills)
            combined_start, combined_end = min(ls, start), max(le, end)
            if combined_end - combined_start <= CLIP_MAX:
                result[-1] = (combined_start, combined_end, prefer_score, merged_stills)
            else:
                prefer = (start, end, score) if score > lscore else (ls, le, lscore)
                center = (prefer[0] + prefer[1]) / 2
                clamped = clamp_window(center, CLIP_MAX, media_duration)
                result[-1] = (clamped[0], clamped[1], prefer_score, merged_stills)
        else:
            result.append((start, end, score, stills))
    return result


def main() -> None:
    a = clamp_window(10, CLIP_MEAN, 120)
    b = clamp_window(28, CLIP_MEAN, 120)
    assert a[1] > b[0], "windows should overlap for this fixture"
    merged = merge_overlapping(
        [(*a, 100.0, ["archive/shots/001.png"]), (*b, 100.0, ["archive/shots/002.png"])],
        120,
    )
    assert merged, "expected a merged window"
    for start, end, _, stills in merged:
        assert end - start <= CLIP_MAX + 1e-6, f"window {end - start}s exceeds cap"
        assert set(stills) == {"archive/shots/001.png", "archive/shots/002.png"}
    later_higher = merge_overlapping(
        [(*a, 80.0, ["archive/shots/001.png"]), (*b, 100.0, ["archive/shots/002.png"])],
        120,
    )
    assert set(later_higher[0][3]) == {"archive/shots/001.png", "archive/shots/002.png"}
    print("slicer cap ok")


if __name__ == "__main__":
    main()
