"""Находки ревью конвейера распознавания (2026-11-14): входы из отчёта, всё синтетика.

Номер в имени теста — номер находки отчёта `drafts/2026-11-14-audit/report-transcription.md`.
"""
from __future__ import annotations

import base64
import json
import time
import wave
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from conftest import SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine import meeting as m
from mostik_engine import seams
from mostik_engine import speech_rules as R
from mostik_engine import verifier_worker, whisper_hint
from mostik_engine.doubts import analyze
from mostik_engine.models import ModelMissing, ModelPool
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine
from mostik_engine.session import Session, extend_final_window
from mostik_engine.verifier_worker import VerifierClient
from test_perf_p1 import _feed
from test_protocol import Sink

from audio_transcription.fillers import strip_fillers
from audio_transcription.glossary import GlossaryEntry
from audio_transcription.models import Segment


def seg(start, end, text, speakers=None):
    return {"start": start, "end": end, "text": text, "speakers": speakers or []}


def write_wav(path: Path, samples: np.ndarray, rate: int = 16000) -> None:
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(samples.astype("<i2").tobytes())


# --- 1, 11, 19: эхо между дорожками ---------------------------------------------------------------

LONG_MINE = ("Да, я согласен, давайте так и сделаем, я подготовлю план к пятнице и пришлю всем на почту, "
             "а потом обсудим бюджет")


def test_01_short_system_reply_does_not_drop_long_mic_turn():
    mic = [seg(0.0, 18.0, LONG_MINE)]
    assert m.drop_echo(mic, [seg(6.0, 7.5, "Так и сделаем.")]) == (mic, 0)
    # Те же слова вразброс — не повтор.
    scattered = [seg(0.0, 18.0, "Да, я посмотрел, и это всё ещё не работает, потому что то место никто не правил")]
    assert m.drop_echo(scattered, [seg(3.0, 4.5, "Да, и это не то.")]) == (scattered, 0)
    # И наоборот: мой короткий ответ не эхо длинной реплики собеседника с теми же словами вразброс.
    mine = [seg(3.0, 4.5, "Да, и это не то.")]
    assert m.drop_echo(mine, [seg(0.0, 18.0, scattered[0]["text"])]) == (mine, 0)


def test_01_real_echo_is_still_dropped():
    system = [seg(10.0, 14.0, "мы выпускаем релиз в пятницу", ["speaker_1"])]
    assert m.drop_echo([seg(10.5, 13.5, "мы выпускаем релизы в пятницу")], system) == ([], 1)
    # Микрофон поймал только хвост фразы собеседника.
    assert m.echo_score("давайте обсудим бюджет", "итак коллеги давайте обсудим бюджет на квартал") >= 0.6


def test_11_my_voice_leaked_into_system_track_stays_mine():
    mic = [seg(10.0, 14.0, "Давайте перенесём релиз на следующую неделю.")]
    system = [seg(10.6, 14.5, "Давайте перенесём релиз на следующую неделю.", ["speaker_1"]),
              seg(20.0, 22.0, "Хорошо, переносим.", ["speaker_1"])]
    kept_mic, kept_system, dropped = m.split_echo(mic, system)
    assert kept_mic == mic and dropped == 1
    assert [item["start"] for item in kept_system] == [20.0]
    turns = m.merge_tracks(kept_mic, kept_system)
    assert [(turn["speaker"], turn["text"]) for turn in turns] == [
        (m.ME, "Давайте перенесём релиз на следующую неделю."), ("Собеседник 1", "Хорошо, переносим.")]


def test_11_ordinary_echo_direction_is_unchanged():
    # Система первой или почти одновременно — эхо в микрофоне, как раньше.
    system = [seg(10.0, 14.0, "Давайте перенесём релиз на следующую неделю.")]
    for start, end in ((10.5, 13.5), (9.9, 14.0)):
        kept_mic, kept_system, dropped = m.split_echo([seg(start, end, system[0]["text"])], system)
        assert (kept_mic, kept_system, dropped) == ([], system, 1)


def test_19_one_or_two_words_are_never_echo():
    mic = [seg(5.0, 5.5, "Да."), seg(8.0, 9.0, "Да, конечно.")]
    system = [seg(5.1, 5.6, "Да."), seg(8.1, 9.1, "Да, конечно.")]
    assert m.drop_echo(mic, system) == (mic, 0)


# --- 2, 3: английское проверяющей и место замены ---------------------------------------------------

def run(primary: str, verifier: str, **kwargs):
    return analyze([Segment(0.0, 5.0, primary)], [Segment(0.0, 5.0, verifier)], language="ru", **kwargs)


@pytest.mark.parametrize("primary, verifier", [
    ("Создай задачу в Slack и напиши команде.", "Создай задачу в Jira и напиши команде."),
    ("Проверь ветку release candidate перед выкладкой.", "Проверь ветку Thanks for watching перед выкладкой."),
    ("Открой GitHub и проверь Kubernetes.", "Открой Git Hub и проверь Cubernetes."),
])
def test_02_verifier_english_is_not_taken_without_evidence(primary, verifier):
    result = run(primary, verifier)
    assert result.segments[0].text == primary
    assert not [fix for fix in result.corrections if fix.rule == "verifier_latin"]


def test_02_verifier_punctuation_is_not_carried_over():
    result = run("Это Fix by Glocy. Дальше идём к тестам.", "Это fixed by glossary, дальше идём к тестам.")
    assert result.segments[0].text == "Это fixed by glossary. Дальше идём к тестам."
    fixes = [(fix.before, fix.after) for fix in result.corrections]
    assert fixes and all(side == side.strip(".,") for pair in fixes for side in pair)


def test_03_canonical_replaces_the_disputed_occurrence():
    master = [GlossaryEntry("master", (), auto_apply=True)]
    result = run("Наш мастер сказал, что надо слить ветку в мастер сегодня.",
                 "Наш мастер сказал, что надо слить ветку в master сегодня.", personal=master)
    assert result.segments[0].text == "Наш мастер сказал, что надо слить ветку в master сегодня."
    result = run("Слей ветку в мастер, а потом наш мастер проверит.",
                 "Слей ветку в master, а потом наш мастер проверит.", personal=master)
    assert result.segments[0].text == "Слей ветку в master, а потом наш мастер проверит."
    cursor = [GlossaryEntry("Cursor", (), auto_apply=True)]
    result = run("Поставь курсор в начало строки и открой курсор заново.",
                 "Поставь курсор в начало строки и открой Cursor заново.", personal=cursor)
    assert result.segments[0].text == "Поставь курсор в начало строки и открой Cursor заново."


def test_03_latin_replaces_the_disputed_occurrence():
    result = run("Нажми Bataun, потом ещё раз Bataun и подожди.", "Нажми Bataun, потом ещё раз button и подожди.")
    assert result.segments[0].text == "Нажми Bataun, потом ещё раз button и подожди."


# --- 4: сбой окна не теряет диктовку ----------------------------------------------------------------

class FlakyPool(FakePool):
    """Сбой на окнах с указанными номерами вызова."""

    def __init__(self, fail: set[int], error: Exception | None = None) -> None:
        super().__init__()
        self.fail = fail
        self.error = error or RuntimeError("whisper: нет ответа на окно")
        self.calls = 0

    def recognize(self, waveform, language, **kwargs):
        self.calls += 1
        if self.calls in self.fail:
            raise self.error
        return super().recognize(waveform, language, **kwargs)


def test_04_failed_window_keeps_the_rest_and_is_not_retried():
    pool = FlakyPool({2})
    session = Session("f", "ru", pool=pool)
    _feed(session, np.concatenate([tone(2), silence(1), tone(2), silence(1), tone(2), silence(1)]))
    result = session.finish()
    assert [bool(window.text) for window in session.windows] == [True, False, True]
    assert pool.calls == 3  # упавшее окно не планируется повторно
    assert result["event"] == "final" and result["text"].count("слово") == 4
    assert result["stats"]["failed_windows"] == 1


def test_04_missing_model_and_total_failure_still_raise():
    session = Session("m", "ru", pool=FlakyPool({1}, ModelMissing("модель не установлена")))
    session.append(pcm16(np.concatenate([tone(2), silence(1)])))
    with pytest.raises(ModelMissing):
        session.finish()
    session = Session("t", "ru", pool=FlakyPool({1}))
    session.append(pcm16(np.concatenate([tone(2), silence(1)])))
    with pytest.raises(RuntimeError):
        session.finish()


def _engine(tmp_path):
    sink = Sink()
    return Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                  personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False)), sink


def test_04_finish_error_still_returns_recognized_text(tmp_path):
    engine, sink = _engine(tmp_path)

    def broken(wait, at, on_wait=None):
        raise RuntimeError("whisper: нет ответа на окно")

    session = SimpleNamespace(id="e1", language="ru", polish=None, finish=broken,
                              live_text=lambda: "Первая длинная фраза диктовки.")
    engine._finish(session, 0, time.monotonic(), 7)
    final = sink.wait(lambda e: e.get("session") == "e1" and e.get("event") in ("final", "error"))
    assert final["event"] == "final" and final["text"] == "Первая длинная фраза диктовки."
    assert final["id"] == 7 and final["polished"] is False and "нет ответа" in final["error"]


def test_04_finish_error_without_text_is_an_error(tmp_path):
    engine, sink = _engine(tmp_path)

    def broken(wait, at, on_wait=None):
        raise RuntimeError("сбой")

    engine._finish(SimpleNamespace(id="e2", language="ru", polish=None, finish=broken, live_text=lambda: ""),
                   0, time.monotonic(), 8)
    event = sink.wait(lambda e: e.get("session") == "e2" and e.get("event") in ("final", "error"))
    assert event["event"] == "error" and event["code"] == "internal"


# --- 5: редкая речь на тихой дорожке -----------------------------------------------------------------

def test_05_rare_speech_on_long_quiet_track_is_usable(tmp_path):
    rate = 16000
    rng = np.random.default_rng(7)
    noise = rng.normal(0.0, 32768 * 10 ** (-70 / 20), 600 * rate)
    t = np.arange(10 * rate) / rate
    noise[300 * rate: 310 * rate] += np.sin(2 * np.pi * 220 * t) * 32768 * 10 ** (-33 / 20) * 2 ** 0.5
    path = tmp_path / "mic.wav"
    write_wav(path, noise)
    duration, level = m.wav_stats(path)
    assert duration == pytest.approx(600.0) and level < m.SILENCE_DBFS  # в среднем — «тишина»
    assert m.track_usable(path) == (True, pytest.approx(600.0))
    quiet = tmp_path / "quiet.wav"
    write_wav(quiet, rng.normal(0.0, 32768 * 10 ** (-70 / 20), 30 * rate))
    assert m.track_usable(quiet) == (False, pytest.approx(30.0))


# --- 6: филлеры не едят единицы и буквы ---------------------------------------------------------------

@pytest.mark.parametrize("raw", [
    "Толщина 5 мм, ширина 10 мм.", "Шаг 2 мм", "Футболка размера эм.", "Вариант Э лучше",
])
def test_06_units_and_letters_are_not_fillers(raw):
    assert strip_fillers(raw) == (raw, 0)


@pytest.mark.parametrize("raw, expected", [
    ("Э, я думаю, что да.", "Я думаю, что да."),
    ("Ну, э, вот так.", "Ну, вот так."),
    ("ну э вот", "ну вот"),
    ("Эм... давайте начнём.", "Давайте начнём."),
    ("Так, мм, ладно.", "Так, ладно."),
    ("Э-э-э, ну да. Хмм. Um, okay.", "Ну да. Okay."),
])
def test_06_real_fillers_are_still_removed(raw, expected):
    assert strip_fillers(raw)[0] == expected


# --- 7: команды только отдельной фразой ---------------------------------------------------------------

@pytest.mark.parametrize("raw, language", [
    ("В таблице появилась новая строка. Проверь её.", "ru"),
    ("Здесь нужен новый абзац.", "ru"),
    ("Добавь проверку, если пришла новая строка, то пропусти.", "ru"),
    ("I added a new line. Check it.", "en"),
])
def test_07_break_commands_ignore_ordinary_speech(raw, language):
    assert R.apply_commands(raw, language) == raw


@pytest.mark.parametrize("raw, language", [
    ("Найди в файле слово временно и зачеркни. Потом сохрани.", "ru"),
    ("If it is wrong, delete that.", "en"),
])
def test_07_scratch_ignores_ordinary_speech(raw, language):
    assert R.apply_scratch(raw, language) == raw
    assert R.apply(raw, language, dict(R.DEFAULT_RULES))[0] == raw


def test_07_scratch_after_ignored_request_still_works():
    raw = "Первое. Найди слово и зачеркни. Второе. Зачеркни. Третье."
    assert R.apply_scratch(raw) == "Первое. Найди слово и зачеркни. Третье."


# --- 8: диапазон не время ----------------------------------------------------------------------------

@pytest.mark.parametrize("raw", [
    "Опоздаю минут на десять пятнадцать.",
    "Это займёт на двадцать тридцать процентов больше времени.",
    "С двадцати тридцати человек собрали отзывы.",
    "до двадцати тридцати процентов",
])
def test_08_range_is_not_a_clock(raw):
    assert R.apply_numbers(raw, "ru") == raw


def test_08_clock_still_works():
    assert R.apply_numbers("с девяти тридцати до десяти", "ru") == "с 9:30 до 10"
    assert R.apply_numbers("начнём в девять сорок пять", "ru") == "начнём в 9:45"


# --- 9: слова, которые числами не являются ------------------------------------------------------------

@pytest.mark.parametrize("raw", [
    "Миллионы людей пользуются этим, тысячи компаний тоже.",
    "Тысячу раз говорил.",
    "Прилетела сорока и села на забор.",
    "Работаю здесь уже второй год.",
    "Это первый годовой отчёт.",
    "Ни одной минуты не потерял.",
    "Через два три дня вернусь.",
    "Кормлю семью год.",
    "первая майка",
])
def test_09_words_that_are_not_numbers_stay_words(raw):
    assert R.apply_numbers(raw, "ru") == raw


@pytest.mark.parametrize("raw, expected", [
    ("тысяча рублей", "1000 рублей"),
    ("около сорока минут", "около 40 минут"),
    ("первого мая", "1 мая"),
    ("в двадцать первом году", "в 21-м году"),
])
def test_09_real_numbers_still_become_digits(raw, expected):
    assert R.apply_numbers(raw, "ru") == expected


def test_09_english_bare_scale_and_range():
    assert R.apply_numbers("a thousand times, twenty thirty people", "en") == "a thousand times, twenty thirty people"
    assert R.apply_numbers("one thousand dollars", "en") == "1000 dollars"


# --- 10: стыки окон ----------------------------------------------------------------------------------

@pytest.mark.parametrize("windows, expected", [
    (["Сделаем это завтра.", "Если не получится, перенесём на пятницу."],
     "Сделаем это завтра. Если не получится, перенесём на пятницу."),
    (["Релиз в пятницу.", "Как дела с тестами?"], "Релиз в пятницу. Как дела с тестами?"),
    (["Хорошо.", "Теперь про бюджет."], "Хорошо. Теперь про бюджет."),
    (["Okay.", "I think we are done."], "Okay. I think we are done."),
    (["Then.", "I go."], "Then I go."),  # английское «I» строчной не пишется
    (["Я думаю.", "Что это правильно."], "Я думаю, что это правильно."),
    # Местоимение после законченного предложения — новое предложение.
    (["Я отправил отчёт.", "Его посмотрит Маша."], "Я отправил отчёт. Его посмотрит Маша."),
    (["Мы обсудили бюджет.", "Их предложение лучше нашего."], "Мы обсудили бюджет. Их предложение лучше нашего."),
    (["Отчёт готов.", "Его надо отправить."], "Отчёт готов. Его надо отправить."),
    (["Надо позвонить Пете.", "Ему нужен доступ."], "Надо позвонить Пете. Ему нужен доступ."),
    # «макет» похож на глагол окончанием — точка модели просто остаётся.
    (["Вот новый макет.", "Её команда уже видела."], "Вот новый макет. Её команда уже видела."),
    # Слева обрывок без сказуемого — местоимение продолжает фразу, как раньше.
    (["Только у Acme.", "И у Globex.", "Его есть достаточно."], "Только у Acme и у Globex его есть достаточно."),
    (["Про вчерашний релиз.", "Его перенесли."], "Про вчерашний релиз его перенесли."),
    # Союзы по-прежнему продолжают фразу и после законченного предложения.
    (["Я отправил отчёт.", "И его посмотрит Маша."], "Я отправил отчёт и его посмотрит Маша."),
])
def test_10_seams_keep_real_sentence_ends(windows, expected):
    assert seams.join_windows(windows) == expected


# --- 12: отменённые окна не держат проверяющую --------------------------------------------------------

class _Process:
    def __init__(self) -> None:
        self.stdin = SimpleNamespace(write=lambda text: None, flush=lambda: None, close=lambda: None)

    def poll(self):
        return None

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


def test_12_cancel_clears_pending_and_lets_sweep_unload():
    client = VerifierClient(idle_s=60.0)
    client._process = _Process()
    client._pending = {"s1:0", "s1:1", "s1:detect", "s2:0", "s11:0"}
    client.cancel("s1")
    assert client._pending == {"s2:0", "s11:0"}
    client.cancel("s2")
    client.cancel("s11")
    assert not client.busy()
    assert client.sweep(now=time.monotonic() + 3600) is True
    assert client._process is None


# --- 13: короткое слово в конце ------------------------------------------------------------------------

class CoarseVadPool(FakePool):
    """Как Silero с `min_speech_duration_ms=250`: речь короче четверти секунды не находит."""

    def speech_spans(self, waveform, **kwargs):
        return [(start, end) for start, end in super().speech_spans(waveform, **kwargs) if end - start >= SR // 4]


def test_13_short_word_after_last_span_reaches_the_model():
    pool = CoarseVadPool()
    session = Session("tail", "ru", pool=pool)
    audio = np.concatenate([tone(3), silence(0.5), tone(0.15), silence(0.15)])
    session.append(pcm16(audio))
    session.finish()
    assert len(session.windows) == 1
    assert session.windows[-1].end == len(audio)
    assert pool.recognized == [pytest.approx(len(audio) / SR)]


def test_13_silence_click_and_long_tail_are_not_added():
    speech = tone(3)
    window = (0, len(speech) + SR // 5)
    quiet = np.concatenate([speech, silence(1.0)])
    assert extend_final_window(quiet, window) == window
    click = np.concatenate([speech, silence(0.5), tone(0.03), silence(0.3)])
    assert extend_final_window(click, window) == window
    far = np.concatenate([speech, silence(2.0), tone(0.15)])
    assert extend_final_window(far, window) == window
    word = np.concatenate([speech, silence(0.5), tone(0.15), silence(0.2)])
    assert extend_final_window(word, window) == (0, len(word))


def test_13_fast_word_after_closed_window_or_long_pause_gets_its_own_window():
    """Остаток после живой проверки: слово короче 250 мс, которое VAD не видит, терялось, если окно
    закрылось раньше `stop` или пауза перед словом длиннее 1,5 с (`extend_final_window` не достаёт)."""
    # Окно закрылось на обычном шаге, слово — уже после.
    pool = CoarseVadPool()
    session = Session("closed", "ru", pool=pool)
    session.append(pcm16(np.concatenate([tone(3), silence(1.0)])))
    session.step()
    assert len(session.windows) == 1
    session.append(pcm16(np.concatenate([silence(1.0), tone(0.15)])))
    session.finish()
    assert len(session.windows) == 2 and session.windows[1].end == session.samples
    assert session.windows[1].start >= session.windows[0].end
    assert pool.recognized[1] < 0.6, "окно — само слово с отступом, а не вся тишина перед ним"

    # Всё одним шагом на stop, но пауза перед словом 2,5 с.
    pool = CoarseVadPool()
    session = Session("far", "ru", pool=pool)
    session.append(pcm16(np.concatenate([tone(3), silence(2.5), tone(0.15)])))
    session.finish()
    assert len(session.windows) == 2 and pool.recognized[1] < 0.6


@pytest.mark.parametrize("tail", [
    silence(1.0),                                             # тишина
    np.concatenate([silence(0.5), tone(0.03), silence(0.3)]),  # щелчок клавиши
    np.concatenate([silence(0.5), tone(0.15, amp=0.02)]),     # шорох в 15 раз тише речи
])
def test_13_silence_click_and_rustle_after_closed_window_add_nothing(tail):
    pool = CoarseVadPool()
    session = Session("quiet", "ru", pool=pool)
    session.append(pcm16(np.concatenate([tone(3), silence(1.0)])))
    session.step()
    session.append(pcm16(tail))
    session.finish()
    assert len(session.windows) == 1 and len(pool.recognized) == 1


# --- 14: Whisper и тишина ------------------------------------------------------------------------------

def test_14_silence_goes_to_the_model_only_when_it_is_safe():
    class WhisperPool(FakePool):
        def speech_spans(self, waveform, **kwargs):
            return []

        def silence_safe(self, language):
            return False

    pool = WhisperPool()
    session = Session("q", "en", pool=pool)
    session.append(pcm16(silence(1.0)))
    assert session.finish()["text"] == "" and pool.recognized == []
    assert ModelPool.silence_safe("ru") is True and ModelPool.silence_safe("en") is False


def test_14_prompt_echo_is_dropped():
    assert whisper_hint.is_prompt_echo("okay, let's look at the task: check the code, fix the tests, "
                                       "and ship the release", "en")
    assert not whisper_hint.is_prompt_echo("Okay, let's look at the task.", "en")
    assert not whisper_hint.is_prompt_echo("", "en")

    class Model:
        def __init__(self, text):
            self.text = text

        def generate(self, audio, **kwargs):
            return SimpleNamespace(text=self.text)

    request = {"window_id": "w", "pcm": base64.b64encode(pcm16(tone(1.0))).decode("ascii"), "language": "en"}
    assert verifier_worker._transcribe(Model(whisper_hint.SAMPLE_PHRASES["en"]), request)["text"] == ""
    assert verifier_worker._transcribe(Model("Ship the release today."), request)["text"] == "Ship the release today."


# --- 15: автоязык при холодном Whisper ----------------------------------------------------------------

class LanguagePool(FakePool):
    """Помнит, на каком языке распознавалось каждое окно."""

    def __init__(self) -> None:
        super().__init__()
        self.languages: list[str] = []

    def recognize(self, waveform, language, **kwargs):
        self.languages.append(language)
        return f"{language}{len(self.languages)}."


class SilentDetector(FakeVerifier):
    """Whisper ещё грузится: окно на определение языка принято, ответа нет."""

    def __init__(self) -> None:
        super().__init__()
        self.detects = 0

    def submit_detect(self, window_id, session, pcm, languages):
        self.detects += 1
        return True


def _bilingual(monkeypatch, status=None, timeout=0.05):
    import mostik_engine.language_detect as ld

    monkeypatch.setattr(ld, "TIMEOUT_S", timeout)
    pool, verifier = LanguagePool(), SilentDetector()
    session = Session("s", "ru", pool=pool, verifier=verifier)
    verifier.sink = session.on_verifier
    session.languages = ["ru", "en"]
    session.detector = verifier.submit_detect
    session.detector_status = status
    changed: list[str] = []
    session.on_language = lambda current: changed.append(current.language)
    return session, pool, verifier, changed


def test_15_late_answer_switches_language_and_redoes_windows(monkeypatch):
    session, pool, verifier, changed = _bilingual(monkeypatch)
    session.append(pcm16(np.concatenate([tone(9), silence(0.6)])))
    session.step()  # срок вышел: окно распознано на языке по умолчанию, пачка ушла проверяющей
    assert session.language == "ru" and pool.languages == ["ru"]
    assert session.language_info["fallback"] is True and session.language_info["reason"] == "timeout"
    assert session.packs[0].submitted
    session.on_verifier({"window_id": "s:detect", "probs": {"ru": 0.02, "en": 0.97}})  # Whisper догрузился
    session.append(pcm16(np.concatenate([tone(2), silence(0.6)])))
    result = session.finish(wait_verifier_ms=200)
    assert result["language"] == "en" and changed == ["en"]
    assert pool.languages == ["ru", "en", "en"], "первое окно распознано заново, второе — сразу на верном языке"
    assert result["raw_text"] == "en2. en3."
    info = result["language_detect"]
    assert info["detected"] == "en" and info["fallback"] is False and info["late"] is True and info["redone"] == 1
    assert "reason" not in info
    assert verifier.cancelled == ["s"], "пачки на старом языке отменены"
    assert [pack.void for pack in session.packs] == [True, False, False]
    assert result["stats"]["windows"] == 2 and result["stats"]["packs"] == 2, "старая пачка в счёт не идёт"
    assert result["verifier"] == "done" and result["stats"]["verified"] == 2
    assert verifier.detects == 1


def test_15_late_answer_with_the_same_language_changes_nothing(monkeypatch):
    session, pool, _, changed = _bilingual(monkeypatch)
    session.append(pcm16(np.concatenate([tone(2), silence(0.6)])))
    session.step()
    session.on_verifier({"window_id": "s:detect", "probs": {"ru": 0.98, "en": 0.01}})
    result = session.finish()
    assert result["language"] == "ru" and changed == [] and pool.languages == ["ru"]
    assert result["language_detect"]["fallback"] is False and result["language_detect"]["late"] is True


def test_15_stop_waits_for_loading_whisper(monkeypatch):
    """Короткая диктовка, Whisper ещё грузится: на `stop` срок считается от готовности процесса."""
    import threading

    state = {"status": ("loading", None)}
    # Срок ответа с запасом: на загруженной машине 20 мс потока растягиваются, и узкий срок давал ложный отказ.
    session, pool, _, changed = _bilingual(monkeypatch, status=lambda: state["status"], timeout=0.5)
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.4)])))

    def load_then_answer():
        time.sleep(1.2)  # заметно дольше срока ответа: без отсчёта от готовности был бы отказ
        state["status"] = ("ready", time.monotonic())
        time.sleep(0.02)
        session.on_verifier({"window_id": "s:detect", "probs": {"ru": 0.02, "en": 0.97}})

    threading.Thread(target=load_then_answer, daemon=True).start()
    result = session.finish()
    assert result["language"] == "en" and changed == ["en"] and pool.languages == ["en"]
    assert result["language_detect"]["fallback"] is False and "redone" not in result["language_detect"]


def test_15_stop_does_not_wait_for_dead_or_silent_whisper(monkeypatch):
    import mostik_engine.language_detect as ld

    for status in (("dead", None), ("ready", time.monotonic() - 60)):
        session, pool, _, changed = _bilingual(monkeypatch, status=lambda status=status: status)
        session.append(pcm16(np.concatenate([tone(1.5), silence(0.4)])))
        started = time.monotonic()
        result = session.finish()
        assert time.monotonic() - started < 1.0
        assert result["language"] == "ru" and result["language_detect"]["reason"] == "timeout"
    # Загрузка затянулась: ждём не дольше общего потолка.
    monkeypatch.setattr(ld, "COLD_WAIT_S", 0.3)
    session, _, _, _ = _bilingual(monkeypatch, status=lambda: ("loading", None))
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.4)])))
    started = time.monotonic()
    assert session.finish()["language_detect"]["fallback"] is True
    assert 0.25 < time.monotonic() - started < 1.5


def test_15_skip_wait_interrupts_waiting_for_language(monkeypatch):
    session, _, _, _ = _bilingual(monkeypatch, status=lambda: ("loading", None))
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.4)])))
    session.skip_wait()
    started = time.monotonic()
    assert session.finish()["language_detect"]["reason"] == "timeout"
    assert time.monotonic() - started < 1.0


def test_15_unsent_detection_is_reported_as_unavailable(monkeypatch):
    session, _, verifier, _ = _bilingual(monkeypatch)
    session.detector = lambda *args: False
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.4)])))
    info = session.finish()["language_detect"]
    assert info["fallback"] is True and info["reason"] == "unavailable"


def test_15_client_status_follows_the_process():
    client = VerifierClient()
    assert client.status() == ("dead", None)
    client._process = _Process()
    assert client.status() == ("loading", None)
    client._ready_at = 12.5
    client._ready.set()
    assert client.status() == ("ready", 12.5)
    client._failed = "нет весов"
    assert client.status() == ("dead", None)


# --- 16: один процесс Whisper на все роли --------------------------------------------------------------

class _Stdout(list):
    """Строки stdout поддельного процесса для `VerifierClient._read`."""


def test_16_engine_gives_the_pool_its_whisper_process(tmp_path, monkeypatch):
    from mostik_engine import models

    eng = Engine(Sink(), personal=PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False))
    whisper = eng.verifier.for_language("ru")
    assert whisper.model == "whisper" and eng.pool._whisper is whisper
    created = []
    monkeypatch.setattr(verifier_worker, "VerifierClient",
                        lambda *args, **kwargs: created.append(kwargs) or VerifierClient(*args, **kwargs))
    monkeypatch.setattr(models, "is_cached", lambda entry: True)
    monkeypatch.setattr(models.RemoteRecognizer, "load", lambda self: None)
    primary = eng.pool.primary("en")
    assert primary.client is whisper and created == [], "второй процесс Whisper не создаётся"
    assert whisper.pinned
    # Пока основная в пуле, общий процесс не гасят ни простой проверяющей, ни её stop.
    whisper._process = _Process()
    assert whisper.sweep(now=time.monotonic() + 3600) is False
    eng.verifier.stop()
    assert whisper._process is not None
    # Основная выгружена по простою — процесс отпущен и уходит обычным простоем проверяющей.
    eng.pool.sweep(now=time.monotonic() + 3600)
    assert not whisper.pinned and not eng.pool.has_primary("en")
    assert whisper.sweep(now=time.monotonic() + 3600) is True and whisper._process is None


def test_16_answers_are_routed_by_window_prefix():
    verifier_answers, primary_answers = [], []
    client = VerifierClient(on_result=verifier_answers.append)
    client.route("primary:", primary_answers.append)
    process = SimpleNamespace(stdout=[
        json.dumps({"ready": True, "seconds": 0.1}) + "\n",
        json.dumps({"window_id": "primary:1", "text": "Hello.", "seconds": 0.9}) + "\n",
        json.dumps({"window_id": "s1:0", "text": "Привет.", "seconds": 0.4}) + "\n",
        json.dumps({"window_id": "s1:detect", "probs": {"ru": 0.9}, "seconds": 1.8}) + "\n",
    ])
    client._process = process
    client._read(process)
    assert [m["window_id"] for m in primary_answers] == ["primary:1"]
    assert [m["window_id"] for m in verifier_answers] == ["s1:0", "s1:detect"]
    assert client.call_ema_s == 0.4, "цена пачки проверяющей не смешивается с окном основной и определением языка"


def test_16_recognizer_submits_urgent_and_gets_its_answer():
    from mostik_engine.models import RemoteRecognizer

    class Shared:
        model = "whisper"
        failure = None

        def __init__(self):
            self.routes, self.pins, self.sent = {}, set(), []

        def route(self, prefix, callback):
            self.routes[prefix] = callback

        def pin(self, owner):
            self.pins.add(owner)

        def unpin(self, owner):
            self.pins.discard(owner)

        def ensure(self):
            return True

        def wait_ready(self, timeout):
            return True

        def running(self):
            return True

        def stop(self):
            raise AssertionError("общий процесс основная модель не гасит")

        def submit(self, window_id, session, pcm, language, hotwords=None, *, urgent=False):
            self.sent.append((window_id, urgent))
            self.routes["primary:"]({"window_id": window_id, "text": " Hello. "})
            return True

    shared = Shared()
    recognizer = RemoteRecognizer("whisper", client=shared)
    assert shared.pins == {"primary:"}
    assert recognizer.recognize(tone(1.0), language="en") == " Hello. "
    assert shared.sent == [("primary:1", True)]
    recognizer.stop()
    assert shared.pins == set()


def test_16_urgent_requests_go_before_verifier_packs():
    import collections

    queue = collections.deque()
    for request in ({"window_id": "s1:0"}, {"window_id": "s1:1"}, {"window_id": "primary:1", "urgent": True},
                    {"window_id": "s2:detect", "urgent": True}, {"window_id": "s1:2"}):
        verifier_worker.enqueue(queue, request)
    assert [item["window_id"] for item in queue] == ["primary:1", "s2:detect", "s1:0", "s1:1", "s1:2"]


# --- 17, 18: дорожки встречи ---------------------------------------------------------------------------

def _finished(output: Path, audio: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "segments.json").write_text('{"readable": []}', encoding="utf-8")
    (output / "manifest.json").write_text(json.dumps({
        "mode": "max", "source": {"size_bytes": audio.stat().st_size}, "diarization_model": None,
    }), encoding="utf-8")


def test_18_other_language_or_speakers_is_not_reused(tmp_path):
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"z" * 10)
    output = tmp_path / "o"
    params = {"language": "ru", "speakers": None, "glossary": None}
    _finished(output, audio)
    assert m.finished_track(output, audio, False, params)  # прогон без записи параметров — как раньше
    m.record_run(output, params, finished=True)
    assert m.finished_track(output, audio, False, params)
    assert not m.finished_track(output, audio, False, {**params, "language": "en"})
    assert not m.finished_track(output, audio, False, {**params, "speakers": 3})
    assert not m.finished_track(output, audio, False, {**params, "glossary": "/tmp/g.yaml"})
    m.record_run(output, params, finished=False)  # прогон оборвался на середине
    assert not m.finished_track(output, audio, False, params)


def test_17_18_meeting_rerun_and_scratch_inside_meeting_folder(tmp_path, monkeypatch):
    out = tmp_path / "meet"
    mic = tmp_path / "mic.wav"
    mic.write_bytes(b"x" * 100)
    stale = out / m.SCRATCH_DIR
    stale.mkdir(parents=True)
    (stale / "mic.joined.wav").write_bytes(b"old")  # осталось от убитого движка
    calls: list[str] = []
    seen: list[bool] = []

    def fake_track(command, **kwargs):
        calls.append(command[command.index("--language") + 1] if "--language" in command else "?")
        seen.append((stale / "mic.joined.wav").exists())
        _finished(out / "mic-transcript", mic)

    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", fake_track)
    monkeypatch.setattr(m, "load_segments", lambda output: [])
    payload = {"mic": str(mic), "system": None, "out_dir": str(out), "language": "ru"}
    m.run_meeting(payload, lambda event: None)
    assert len(calls) == 1 and seen == [False]  # брошенная склейка убрана до прогона
    assert not stale.exists()  # и после прогона папки нет
    m.run_meeting(payload, lambda event: None)
    assert len(calls) == 1  # те же параметры — готовая дорожка берётся
    m.run_meeting({**payload, "language": "en"}, lambda event: None)
    assert len(calls) == 2  # другой язык — расшифровка заново
