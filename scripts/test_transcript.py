#!/usr/bin/env python3
"""Mirror of TranscriptQuery.merge + CaptureAudioLayout.shouldTranscribeMovie."""

from __future__ import annotations


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def overlap_fraction(a: tuple[float, float], b: tuple[float, float]) -> float:
    start = max(a[0], b[0])
    end = min(a[1], b[1])
    overlap = max(0.0, end - start)
    shorter = max(0.001, min(a[1] - a[0], b[1] - b[0]))
    return overlap / shorter


def similar_text(a: str, b: str) -> bool:
    na, nb = normalize(a), normalize(b)
    if not na or not nb:
        return False
    if na == nb or na in nb or nb in na:
        return True
    sa, sb = set(na.split()), set(nb.split())
    union = len(sa | sb)
    if union == 0:
        return False
    return len(sa & sb) / union >= 0.75


def collapse(segments: list[tuple[float, float, str, str]]) -> list[tuple[float, float, str, str]]:
    result: list[tuple[float, float, str, str]] = []
    for start, end, text, speaker in segments:
        if (
            result
            and overlap_fraction((result[-1][0], result[-1][1]), (start, end)) >= 0.5
            and similar_text(result[-1][2], text)
        ):
            ls, le, lt, lp = result[-1]
            merged_text = text if len(text) > len(lt) else lt
            merged_speaker = lp
            if lp != speaker and speaker not in lp and lp not in speaker:
                merged_speaker = f"{lp}+{speaker}"
            result[-1] = (min(ls, start), max(le, end), merged_text, merged_speaker)
        else:
            result.append((start, end, text, speaker))
    return result


def merge(passes: list[tuple[str, list[tuple[float, float, str]]]]) -> list[tuple[float, float, str, str]]:
    labeled: list[tuple[float, float, str, str]] = []
    for speaker, segs in passes:
        for start, end, text in segs:
            if text.strip():
                labeled.append((start, end, text, speaker))
    labeled.sort(key=lambda item: (item[0], item[1]))
    return collapse(labeled)


def should_transcribe_movie(*, microphone_wav: bool, system_in_movie: bool, wav_exists: bool, movie_exists: bool) -> bool:
    if not movie_exists or not system_in_movie:
        return False
    if microphone_wav:
        return True
    return not wav_exists


def main() -> None:
    assert should_transcribe_movie(microphone_wav=True, system_in_movie=True, wav_exists=True, movie_exists=True)
    assert not should_transcribe_movie(microphone_wav=False, system_in_movie=True, wav_exists=True, movie_exists=True)
    assert should_transcribe_movie(microphone_wav=False, system_in_movie=True, wav_exists=False, movie_exists=True)
    assert not should_transcribe_movie(microphone_wav=True, system_in_movie=True, wav_exists=True, movie_exists=False)

    merged = merge(
        [
            (
                "room",
                [
                    (1.0, 3.0, "this does nothing"),
                    (10.0, 12.0, "restart ingest-worker"),
                ],
            ),
            (
                "system",
                [
                    (1.1, 3.1, "this does nothing"),
                    (4.0, 6.0, "enable TRACE_SYNC"),
                ],
            ),
        ]
    )
    texts = [item[2] for item in merged]
    assert texts.count("this does nothing") == 1
    assert "enable TRACE_SYNC" in texts
    assert "restart ingest-worker" in texts
    assert len(merged) == 3

    distinct = merge(
        [
            ("room", [(2.0, 4.0, "save is disabled")]),
            ("system", [(2.2, 3.8, "restart the worker now")]),
        ]
    )
    assert len(distinct) == 2
    print("transcript merge ok")


if __name__ == "__main__":
    main()
