"""Встреча расшифровывается без ffmpeg — свои WAV transcriber читает сам."""
from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

import numpy as np
import pytest

from mostik_engine import meeting, paths

paths.setup_import_path()
from audio_transcription import audio  # type: ignore  # noqa: E402
from audio_transcription.models import Section  # type: ignore  # noqa: E402


def _write(path: Path, samples: np.ndarray, *, rate: int, channels: int = 1, width: int = 2) -> Path:
    interleaved = np.repeat(samples[:, None], channels, axis=1).reshape(-1)
    if width == 1:
        data = (np.clip(interleaved, -1, 0.999) * 128 + 128).astype(np.uint8).tobytes()
    elif width == 3:
        ints = np.round(interleaved * ((1 << 23) - 1)).astype(np.int32)
        data = b"".join(struct.pack("<i", int(v))[:3] for v in ints)
    else:
        dtype, scale = ("<i2", 32767) if width == 2 else ("<i4", (1 << 31) - 1)
        data = np.round(interleaved * scale).astype(dtype).tobytes()
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(width)
        handle.setframerate(rate)
        handle.writeframes(data)
    return path


def _tone(rate: int, seconds: float, hz: float = 440.0) -> np.ndarray:
    t = np.arange(int(rate * seconds)) / rate
    return (0.5 * np.sin(2 * math.pi * hz * t)).astype(np.float32)


def _read(path: Path) -> tuple[tuple[int, int, int], np.ndarray]:
    with wave.open(str(path), "rb") as handle:
        params = (handle.getnchannels(), handle.getsampwidth(), handle.getframerate())
        frames = handle.readframes(handle.getnframes())
    return params, np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768


@pytest.fixture
def no_ffmpeg(monkeypatch):
    """Как на чистом Mac: ни ffmpeg, ни ffprobe не находятся."""
    monkeypatch.setattr(audio, "find_command", lambda name: None)


def test_own_track_needs_no_ffmpeg(tmp_path, no_ffmpeg):
    source = _write(tmp_path / "mic.wav", _tone(16_000, 2.0), rate=16_000)
    info = audio.probe_media(source)
    assert info.duration_seconds == pytest.approx(2.0)
    assert (info.sample_rate, info.channels, info.codec) == (16_000, 1, "pcm_s16le")
    assert info.sha256 and info.size_bytes == source.stat().st_size

    prepared, _ = audio.prepare_audio(source, tmp_path / "work")
    params, samples = _read(prepared)
    assert params == (1, 2, 16_000)
    assert len(samples) == 32_000
    with wave.open(str(source), "rb") as original:
        assert prepared.read_bytes()[44:] == original.readframes(original.getnframes()), "16 kHz mono — без изменений"


@pytest.mark.parametrize("rate,channels,width", [(48_000, 2, 2), (44_100, 1, 3), (8_000, 1, 1), (32_000, 2, 4)])
def test_other_pcm_is_converted_to_16k_mono(tmp_path, no_ffmpeg, rate, channels, width):
    source = _write(tmp_path / "in.wav", _tone(rate, 1.0), rate=rate, channels=channels, width=width)
    prepared, info = audio.prepare_audio(source, tmp_path / "work")
    params, samples = _read(prepared)
    assert params == (1, 2, 16_000) and info.channels == channels and info.sample_rate == rate
    assert abs(len(samples) - 16_000) <= 1
    body = samples[1000:-1000]
    assert np.sqrt(np.mean(body**2)) == pytest.approx(0.5 / math.sqrt(2), rel=0.05), "тон не потерял уровень"
    spectrum = np.abs(np.fft.rfft(body))
    assert np.argmax(spectrum) * 16_000 / len(body) == pytest.approx(440, abs=3), "частота та же"


def test_downsampling_filters_above_nyquist(tmp_path, no_ffmpeg):
    """Тон 12 kHz из 48 kHz не должен заворачиваться в речевую полосу 16-килогерцевой записи."""
    source = _write(tmp_path / "high.wav", _tone(48_000, 1.0, hz=12_000), rate=48_000)
    prepared, _ = audio.prepare_audio(source, tmp_path / "work")
    _, samples = _read(prepared)
    assert np.sqrt(np.mean(samples[1000:-1000] ** 2)) < 0.02


def test_section_trims_wav(tmp_path, no_ffmpeg):
    source = _write(tmp_path / "mic.wav", _tone(16_000, 3.0), rate=16_000)
    prepared, info = audio.prepare_audio(source, tmp_path / "work", Section(1.0, 2.5))
    _, samples = _read(prepared)
    assert len(samples) == 24_000
    assert info.duration_seconds == pytest.approx(1.5)


def test_other_format_without_ffmpeg_explains(tmp_path, no_ffmpeg):
    source = tmp_path / "call.m4a"
    source.write_bytes(b"\x00\x00\x00\x20ftypM4A " + b"\x00" * 64)
    with pytest.raises(audio.MediaToolError) as error:
        audio.probe_media(source)
    message = str(error.value)
    assert "WAV" in message and "brew install ffmpeg" in message


def test_float_wav_goes_to_ffmpeg(tmp_path):
    """IEEE float `wave` не читает — такой файл остаётся за ffmpeg, а не ломается молча."""
    source = tmp_path / "float.wav"
    data = np.zeros(160, dtype="<f4").tobytes()
    header = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 1, 16000, 64000, 4, 32)
              + b"data" + struct.pack("<I", len(data)))
    source.write_bytes(header + data)
    assert audio.native_wav(source) is None


def test_meeting_skips_media_tool_check_for_wav(tmp_path, monkeypatch):
    """Подозрительный ffmpeg в общей папке не ломает встречу, которой он не нужен."""
    tool = tmp_path / "ffmpeg"
    tool.write_text("#!/bin/sh\n")
    tool.chmod(0o777)
    monkeypatch.setattr(meeting, "media_tool_candidates", lambda env: [tool])
    track = _write(tmp_path / "mic.wav", _tone(16_000, 1.0), rate=16_000)
    meeting.check_media_tools({"PATH": "/usr/bin"}, track)
    other = tmp_path / "call.m4a"
    other.write_bytes(b"not a wav")
    with pytest.raises(meeting.MeetingTrackError):
        meeting.check_media_tools({"PATH": "/usr/bin"}, other)
