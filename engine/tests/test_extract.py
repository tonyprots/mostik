"""Правила извлечения S3 на маленьких текстах: что берём, что выбрасываем, какой вид."""
from __future__ import annotations

from mostik_engine import extract as ex

DOC = """# Интеграция Mostik и GigaAM

Вчера Антон обсуждал с клиентом проект «Альфа». Потом Антон ушёл.
Модель GPT4o хранит данные в S3, версия 1.2.3 и v2, коммит 3fa9c1e2b.
Пишите на ivan@yandex.ru или @ivan, ссылка https://example.com/Kafka и путь /usr/local/Bin.
Класс EngineClient и функция load_vad работают через API и ОТК. Мы используем launchd.
Петров сказал. А потом Петров ушёл.
"""


def kinds(found):
    return {term: record[1] for term, record in found.items()}


def test_takes_terms_by_shape_and_context():
    found = ex.terms_from_document(DOC)
    got = kinds(found)
    assert got["GPT4o"] == "tech" and got["S3"] == "tech"
    assert got["EngineClient"] == "identifier" and got["load_vad"] == "identifier"
    assert got["API"] == "acronym" and got["ОТК"] == "acronym"
    assert got["Альфа"] == "project"  # кодовое имя после «проект»
    assert got["Mostik"] == "tech" and "GigaAM" in got  # заголовок
    assert got["launchd"] == "tech"  # латиница в русском тексте
    assert got["Антон"] == "person"


def test_drops_noise():
    got = set(ex.terms_from_document(DOC))
    # Числа, версии, хэши, почта, логины, URL, пути.
    assert not got & {"1", "2", "3", "v2", "3fa9c1e2b", "ivan", "yandex", "example", "Kafka", "usr", "Bin"}
    # Словарные слова и слова в начале предложения.
    assert not got & {"Вчера", "Потом", "Модель", "Класс", "Пишите", "Мы", "Интеграция"}
    assert "com" not in got


def test_lines_are_recorded():
    found = ex.terms_from_document(DOC)
    assert found["Mostik"][2] == 1
    assert found["GPT4o"][2] == 4
    assert found["EngineClient"][2] == 6


def test_proper_name_needs_repeat_flag():
    found = ex.terms_from_document(DOC)
    # «Антон» не в начале предложения дважды: кандидат с условием повтора и частотой 2.
    assert found["Антон"][0] == 2 and found["Антон"][3] == 1
    # «Петров» второй раз — в начале предложения не считается, остаётся одно вхождение.
    assert found["Петров"][0] == 1


def test_rejected_rules():
    for word in ("v2", "1.2.3", "2026-10-10", "deadbeef12", "abcdef0123456", "a", "ab", "OK", "THE", "the", "работа"):
        assert ex.rejected(word), word
    for word in ("S3", "UI", "GPT4o", "load_vad", "Parakeet", "ОТК"):
        assert not ex.rejected(word), word


def test_noise_chunks():
    for chunk in ("https://x.org/a", "www.site.ru", "ivan@yandex.ru,", "@login", "/usr/bin", "~/notes", "a\\b"):
        assert ex.is_noise_chunk(chunk), chunk
    assert not ex.is_noise_chunk("GigaAM,")


def test_shape_kind():
    assert ex.shape_kind("ОТК") == "acronym"
    assert ex.shape_kind("GPT4o") == "tech"
    assert ex.shape_kind("TermIndex") == "identifier"
    assert ex.shape_kind("HTTPServer") == "identifier"
    assert ex.shape_kind("snake_case") == "identifier"
    assert ex.shape_kind("Parakeet") is None


def test_english_text_does_not_take_plain_words():
    found = ex.terms_from_document("We ship the build on Monday. Then Daniel reviews it with Daniel again.\n")
    assert "ship" not in found and "build" not in found and "Monday" not in found
    assert found["Daniel"][1] == "tech" and found["Daniel"][3] == 1  # латинское имя собственное


def test_code_fence_and_codename_variants():
    text = "Работаем по project Vega.\n```\nfoo_bar = 1\n```\nКодовое имя: codename Orion для клиента Acme.\n"
    got = kinds(ex.terms_from_document(text))
    assert got["Vega"] == "project" and got["Orion"] == "project"
    assert got["foo_bar"] == "identifier"


def test_title_and_names():
    found = ex.terms_from_title("Синк Mostik с командой ОТК")
    # Первое слово названия — просто заглавная буква, не имя.
    assert kinds(found) == {"Mostik": "project", "ОТК": "acronym"}
    assert kinds(ex.terms_from_title("Планёрка по «Альфа» с Ромашкой")) == {"Альфа": "project", "Ромашкой": "project"}
    assert ex.name_terms("Иван Петров") == ["Иван Петров", "Иван", "Петров"]
    assert ex.name_terms("ivan@yandex.ru") == []
    assert ex.name_terms("Аня") == ["Аня"]


def test_quoted_ui_labels_are_not_names():
    text = "Откройте вкладку «Словарь» и «Словарь» снова. Нажмите кнопку «Записать», потом «Записать».\n"
    found = ex.terms_from_document(text)
    assert "Словарь" not in found and "Записать" not in found


def test_codename_trigger_chain_and_units():
    found = ex.terms_from_document("Слова «проект», «клиент», «project», «codename» ведут к имени. Нужно 4 ГБ и 2 МБ.\n")
    assert not set(found) & {"клиент", "project", "codename", "ГБ", "МБ"}


def test_transcript_labels_start_a_phrase():
    # Живые строки расшифровок 2026-10-19: «Короче», «Перекрытие», «Независимый» попадали в имена людей.
    text = ("[00:07:40.672] Спикер 1: Короче, не вижу смысла.\n"
            "[00:00:40.020] Перекрытие (Спикер 2 + Спикер 3): Нет, я имею в виду\n"
            "- Причина: Независимый mlx-community: различаются токены\n") * 2
    found = ex.terms_from_document(text, markdown=True)
    assert not set(found) & {"Короче", "Перекрытие", "Независимый", "Нет"}


def test_plain_english_words_are_not_terms():
    # Строчное английское слово по словарю macOS — не термин; заглавная, цифры, «_» — термин.
    assert ex.rejected("row") and ex.rejected("frames") and ex.rejected("video")
    for word in ("launchd", "React", "S3", "load_vad", "GigaAM"):
        assert not ex.rejected(word), word
    got = set(ex.terms_from_document("Вчера сохраняли каждую row и каждое video через launchd, а потом переписали на React.\n"))
    assert "launchd" in got and "React" in got
    assert not got & {"row", "video"}
