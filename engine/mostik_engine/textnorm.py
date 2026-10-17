"""Нормализация текста для поиска «Спросить» (M8): токены, стемминг, стоп-слова.

Эмбеддингов на машине нет, поэтому поиск лексический (SQLite FTS5, BM25), и
падежи («встреча», «встречи», «на встрече») сводит стеммер. Русский — алгоритм
Snowball (Портер для русского) на регулярках, английский — лёгкая обрезка
окончаний. Почему стемминг, а не триграммы, — замер в `docs/bench.md`
(раздел «Спросить»): на синтетике у стемминга MRR выше (0,903 против 0,886),
а индекс триграмм в 2,7 раза больше.
"""
from __future__ import annotations

import re

_TOKEN = re.compile(r"[0-9A-Za-zА-Яа-яЁё]+(?:[-_.][0-9A-Za-zА-Яа-яЁё]+)*")
_CYRILLIC = re.compile(r"[А-Яа-яЁё]")

# --- русский: Snowball ---------------------------------------------------------

_VOWELS = "аеиоуыэюя"
_RV = re.compile(rf"^(.*?[{_VOWELS}])(.*)$")
_PERFECTIVE_GERUND = re.compile(r"((ив|ивши|ившись|ыв|ывши|ывшись)|((?<=[ая])(в|вши|вшись)))$")
_REFLEXIVE = re.compile(r"(с[яь])$")
_ADJECTIVE = re.compile(r"(ее|ие|ые|ое|ими|ыми|ей|ий|ый|ой|ем|им|ым|ом|его|ого|ему|ому|их|ых|ую|юю|ая|яя|ою|ею)$")
_PARTICIPLE = re.compile(r"((ивш|ывш|ующ)|((?<=[ая])(ем|нн|вш|ющ|щ)))$")
_VERB = re.compile(
    r"((ила|ыла|ена|ейте|уйте|ите|или|ыли|ей|уй|ил|ыл|им|ым|ен|ило|ыло|ено|ят|ует|уют|ит|ыт|ены|ить|ыть|ишь|ую|ю)"
    r"|((?<=[ая])(ла|на|ете|йте|ли|й|л|ем|н|ло|но|ет|ют|ны|ть|ешь|нно)))$"
)
_NOUN = re.compile(
    r"(а|ев|ов|ие|ье|е|иями|ями|ами|еи|ии|и|ией|ей|ой|ий|й|иям|ям|ием|ем|ам|ом|о|у|ах|иях|ях|ы|ь|ию|ью|ю|ия|ья|я)$"
)
_DERIVATIONAL = re.compile(rf".*[^{_VOWELS}]+[{_VOWELS}].*ость?$")
_DER = re.compile(r"ость?$")
_SUPERLATIVE = re.compile(r"(ейше|ейш)$")


def stem_ru(word: str) -> str:
    """Основа русского слова по Snowball: «встречи», «встрече», «встречу» → «встреч»."""
    word = word.lower().replace("ё", "е")
    match = _RV.match(word)
    if match is None:
        return word
    head, rv = match.groups()
    temp = _PERFECTIVE_GERUND.sub("", rv, 1)
    if temp == rv:
        rv = _REFLEXIVE.sub("", rv, 1)
        temp = _ADJECTIVE.sub("", rv, 1)
        if temp != rv:
            rv = _PARTICIPLE.sub("", temp, 1)
        else:
            temp = _VERB.sub("", rv, 1)
            rv = _NOUN.sub("", rv, 1) if temp == rv else temp
    else:
        rv = temp
    rv = re.sub(r"и$", "", rv, count=1)
    if _DERIVATIONAL.match(rv):
        rv = _DER.sub("", rv, 1)
    temp = re.sub(r"ь$", "", rv, count=1)
    if temp == rv:
        rv = _SUPERLATIVE.sub("", rv, 1)
        rv = re.sub(r"нн$", "н", rv, count=1)
    else:
        rv = temp
    return head + rv


# --- английский: лёгкая обрезка --------------------------------------------------

def stem_en(word: str) -> str:
    """Множественное число, -ing, -ed, -ly: «meetings» → «meet», «delayed» → «delay»."""
    word = word.lower()
    if word.endswith("'s"):
        word = word[:-2]
    if len(word) <= 3:
        return word
    for suffix, replacement, minimum in (
        ("ies", "y", 5), ("sses", "ss", 5), ("ings", "", 7), ("ing", "", 6), ("edly", "", 7),
        ("ed", "", 5), ("ly", "", 6), ("es", "", 6), ("s", "", 4),
    ):
        if word.endswith(suffix) and len(word) >= minimum and not word.endswith("ss"):
            word = word[: len(word) - len(suffix)] + replacement
            break
    # «running» → «runn» → «run»: удвоенная согласная после обрезки.
    if len(word) > 3 and word[-1] == word[-2] and word[-1] not in "aeiouls":
        word = word[:-1]
    return word


# --- стоп-слова ------------------------------------------------------------------

STOP_RU = frozenset("""
а без более бы был была были было быть в вам вас весь во вот все всего всех вы где да даже для до его ее ей
если есть еще же за здесь и из или им их к как ко когда кто ли либо мне может мы на над надо наш не него
нее нет ни них но ну о об однако он она они оно от очень по под при про с со так также такой там те тем то
того тоже той только том ты у уже хотя чего чей чем что чтобы чье чья эта эти это этот я ли какой какая
какие каком какую который которая которые сколько почему зачем откуда куда где-то мной нам нами
скажи расскажи напомни подскажи покажи найди говорили говорил говорила сказал сказала обсуждали решили
""".split())

STOP_EN = frozenset("""
a an the and or but if of to in on at by for with about from into over after before as is are was were be been
being do does did have has had i you he she it we they me my our your his her its their them this that these those
what which who whom whose when where why how all any some no not so than too very can could should would will
just there here tell remind show find did said say discussed decided please
""".split())


def is_cyrillic(text: str) -> bool:
    return bool(_CYRILLIC.search(text))


def question_language(text: str) -> str:
    """Язык вопроса: кириллицы больше, чем латиницы, — `ru`, иначе `en`."""
    cyr = len(_CYRILLIC.findall(text))
    lat = len(re.findall(r"[A-Za-z]", text))
    return "ru" if cyr >= lat and cyr > 0 else ("en" if lat else "ru")


def tokens(text: str) -> list[str]:
    """Слова текста в нижнем регистре; ё → е; дефисные и точечные имена — целиком и частями."""
    found: list[str] = []
    for match in _TOKEN.finditer(text):
        word = match.group(0).lower().replace("ё", "е")
        found.append(word)
        if any(sep in word for sep in "-_."):
            found.extend(part for part in re.split(r"[-_.]", word) if part)
    return found


def stem(word: str) -> str:
    if word.isdigit():
        return word
    return stem_ru(word) if is_cyrillic(word) else stem_en(word)


def normalize(text: str) -> str:
    """Текст → строка основ через пробел; её и хранит индекс FTS5."""
    return " ".join(stem(word) for word in tokens(text))


def query_terms(text: str) -> list[str]:
    """Основы вопроса без стоп-слов и повторов; из одних стоп-слов — все основы."""
    words = tokens(text)
    kept = [w for w in words if w not in STOP_RU and w not in STOP_EN and (len(w) > 1 or w.isdigit())]
    stems: list[str] = []
    for word in kept or words:
        value = stem(word)
        if value and value not in stems:
            stems.append(value)
    return stems
