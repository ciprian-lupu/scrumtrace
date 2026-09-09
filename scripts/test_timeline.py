#!/usr/bin/env python3
"""Mirror of TimelineMath for Linux verification of the pause contract."""

from __future__ import annotations


def paused_delta(wall: float, pauses: list[tuple[float, float | None]]) -> float:
    total = 0.0
    for pause_at, resume in pauses:
        if resume is not None:
            if resume <= wall:
                total += max(0.0, resume - pause_at)
            elif pause_at < wall:
                total += max(0.0, wall - pause_at)
        elif pause_at < wall:
            total += max(0.0, wall - pause_at)
    return total


def media_time(wall: float, pauses: list[tuple[float, float | None]]) -> float:
    return max(0.0, wall - paused_delta(wall, pauses))


def wall_time(media: float, pauses: list[tuple[float, float | None]]) -> float:
    completed = sorted(
        [(p, r) for p, r in pauses if r is not None],
        key=lambda item: item[0],
    )
    wall = media
    for pause_at, resume in completed:
        if pause_at <= wall:
            wall += max(0.0, resume - pause_at)
    return wall


def even_capture_size(width: int, height: int) -> tuple[int, int]:
    w = max(width, 2)
    h = max(height, 2)
    if w > 1920:
        h = max(int(round(h * 1920.0 / w)), 2)
        w = 1920
    if h > 1080:
        w = max(int(round(w * 1080.0 / h)), 2)
        h = 1080
    w -= w % 2
    h -= h % 2
    return max(w, 2), max(h, 2)


def assert_close(actual: float, expected: float, label: str) -> None:
    if abs(actual - expected) > 1e-6:
        raise SystemExit(f"{label}: {actual} != {expected}")


def main() -> None:
    pauses = [(190.0, 205.0)]
    assert_close(media_time(188, pauses), 188, "m188")
    assert_close(media_time(205, pauses), 190, "m205")
    assert_close(media_time(220, pauses), 205, "m220")
    assert_close(wall_time(188, pauses), 188, "w188")
    assert_close(wall_time(190, pauses), 205, "w190")

    pauses2 = [(10.0, 20.0), (50.0, 80.0)]
    assert_close(media_time(5, pauses2), 5, "two-5")
    assert_close(media_time(20, pauses2), 10, "two-20")
    assert_close(media_time(50, pauses2), 40, "two-50")
    assert_close(media_time(80, pauses2), 40, "two-80")
    assert_close(media_time(90, pauses2), 50, "two-90")

    active = [(12.0, None)]
    assert_close(media_time(12, active), 12, "active-12")
    assert_close(media_time(30, active), 12, "active-30")

    mixed = [(10.0, 20.0), (50.0, None)]
    assert_close(media_time(60, mixed), 40, "mixed-active")

    # Stop while paused closes the active interval at stop wall; media stays frozen.
    stopped = [(10.0, 20.0), (50.0, 55.0)]
    assert_close(media_time(55, stopped), 40, "stop-while-paused")
    assert_close(media_time(80, stopped), 65, "after-stop-closed")

    assert even_capture_size(1920, 1080) == (1920, 1080)
    rw, rh = even_capture_size(3024, 1964)
    assert rw % 2 == 0 and rh % 2 == 0
    assert rw <= 1920 and rh <= 1080
    ow, rh2 = even_capture_size(1367, 769)
    assert ow % 2 == 0 and rh2 % 2 == 0
    print("timeline contract ok")


if __name__ == "__main__":
    main()
