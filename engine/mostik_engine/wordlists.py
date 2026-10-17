"""Словарные слова: то, что диктуют как обычную речь, а не как термин.

В transcriber частотных списков языка нет (`fillers`,
`glossary`, `mining` держат только слова-паразиты и правила формы), из сети
ничего не берём (§7). Поэтому здесь небольшие встроенные списки: самые частые
слова английского и русского плюс служебные имена кода. Сравнение — по
`casefold`, для русского — по словоформе целиком (без морфологии): список
защищает в первую очередь от слов с заглавной в заголовках и после «проект».
"""
from __future__ import annotations

# Служебные имена кода и общие слова из программистского английского: их
# диктуют как обычную речь, сомнением они быть не должны.
CODE_COMMON = frozenset(
    """
    the and for are but not you all any can had her was one our out day get has him his how man new
    now old see two way who boy did its let put say she too use that with have this will your from
    they know want been good much some time very when come here just like long make many more only
    over such take than them well were what about after again also back because before being
    between both could down each even every first find give great into last little look most must
    never next other people place right same should since still such than then there these thing
    think those through under until used want water where which while work world would year years
    able above across actually add added again against already always another anything around
    available away become begin best better big bring build built call called case change check
    clear close code common complete content context could create current data default delete
    different done during else empty end error event example false file files find first fix
    follow form format found free full function general given group handle hello help high hold
    home idea image include index info information input inside instance item items keep key kind
    known large later left level line link list load local lock log main make map mark match may
    message method mode model models more move name need next node none note number object off
    open option options order output page part pass path point print private process public read
    real record remove request result return run save search second section self send server set
    show side simple size small sort source start state status step stop store string support sure
    system table task test text there time title token tool top true type update user value values
    version view wait want watch window word words write yes zero init main args kwargs str int
    float bool dict list tuple none null nil void var val let const def class func struct enum impl
    self this super static async await yield import export from return lambda new delete try catch
    except finally raise throw throws public private protected internal open final override
    readme license changelog setup config configs settings utils util helpers helper common core
    base lib libs src test tests spec specs docs doc example examples tmp temp misc app apps
    cli api run runs runner main mod package packages module modules script scripts service
    services client clients server handler handlers manager managers factory provider providers
    view views controller controllers component components store state reducer action actions
    item items entry entries value values result results response request error errors event
    events callback callbacks option options param params parameter parameters argument arguments
    file files path paths dir dirs folder name names id ids key keys type types data info meta
    get set put post patch head add remove update create read write load save open close start
    stop begin end next prev first last count size length len min max sum avg total index
    format parse build make check validate render handle process apply call invoke execute
    string strings number numbers text texts line lines word words char chars byte bytes
    true false yes no on off ok none empty default defaults
    """.split()
)

# Частые английские слова естественного языка, включая то, что пишут с
# заглавной без того, чтобы это было именем: дни, месяцы, языки.
COMMON_EN = frozenset(
    """
    a an the and or but if then else when while for nor so yet of to in on at by with from into onto
    upon about above below over under after before between through during without within along
    across against among around behind beyond near off out up down via per than as like unlike
    i me my mine we us our ours you your yours he him his she her hers it its they them their theirs
    this that these those who whom whose which what where why how all any both each few more most
    other some such no not only own same too very can will just should now also again ever never
    always often sometimes usually here there today tomorrow yesterday yes ok okay please thanks
    thank hello hi dear regards best is am are was were be been being have has had having do does
    did doing would could might must shall may need let make made get got go goes went gone come
    came take took see saw seen know knew think thought say said tell told give gave use used find
    found want work works worked call called try tried ask asked feel felt keep kept leave left put
    mean meant show showed hear heard play run move live believe bring happen write provide sit
    stand lose pay meet include continue set learn change lead understand watch follow stop create
    speak read allow add spend grow open walk win offer remember love consider appear buy wait serve
    die send expect build stay fall cut reach kill remain suggest raise pass sell require report
    decide pull note notes overview introduction summary conclusion background goal goals plan plans
    status todo done draft final next step steps how-to guide usage install installation
    requirements features feature roadmap faq contents table appendix references links contacts
    contributing license changelog release releases version news update updates
    one two three four five six seven eight nine ten first second third new old good bad great
    small large big long short high low early late right wrong true false real main important
    general public private local global open close free full empty easy hard simple possible
    able sure clear different same next last little own whole several many much less least
    monday tuesday wednesday thursday friday saturday sunday
    january february march april may june july august september october november december
    english russian german french spanish chinese japanese american european
    mr mrs ms dr etc e.g i.e vs
    time year years day days week weeks month months hour hours minute minutes people person man
    woman child world life hand part place case point thing things way company system program
    question questions answer answers problem problems number group fact idea business issue
    side kind head house service friend father mother power money night area water room level
    office door health art war history party result change morning reason research girl guy
    moment air teacher force education team meeting meetings project projects client clients
    task tasks review notes agenda action actions item items owner owners deadline
    """.split()
)

# Частые русские слова: служебные, местоимения, частые глаголы и
# существительные. Словоформы перечислены там, где они часто встают с
# заглавной (начало пункта списка, заголовок, после «проект»).
COMMON_RU = frozenset(
    """
    и в во не что он на я с со как а то все всё она так его но да ты к ко у же вы за бы по только
    ее её мне было вот от меня еще ещё нет о об обо из ему теперь когда даже ну вдруг ли если уже
    или ни быть был была были него до вас нибудь опять уж вам ведь там потом себя ничего ей может
    они тут где есть надо ней для мы тебя их чем сам сама сами чтоб чтобы без будто чего раз тоже
    себе под будет ж тогда кто этот эта это эти того потому этого какой какая какое какие совсем
    ним здесь этом один одна одно одни почти мой моя моё мое мои тем нее неё сейчас куда зачем
    всех никогда можно при наконец два об другой другая другое другие хоть после над больше тот
    та те через этих нас про всего них какая много разве три эту моя впрочем хорошо свою этой
    перед иногда лучше чуть том нельзя такой такая такое такие им более всегда конечно всю между
    также кроме около вместо ради благодаря согласно вокруг среди сквозь вдоль мимо
    наш наша наше наши ваш ваша ваше ваши свой своя своё свое свои который которая которое
    которые которых которым весь вся всю всем всеми каждый каждая каждое каждые любой любая
    сначала затем далее итак однако поэтому например кстати значит вообще просто именно
    очень еще уже сразу снова вместе пока почему зачем откуда сюда туда отсюда оттуда
    сегодня завтра вчера утром днём днем вечером ночью сейчас потом позже раньше
    да нет спасибо пожалуйста привет здравствуйте добрый доброе день вечер утро
    понедельник вторник среда среду четверг пятница пятницу суббота субботу воскресенье
    январь февраль март апрель май июнь июль август сентябрь октябрь ноябрь декабрь
    января февраля марта апреля мая июня июля августа сентября октября ноября декабря
    это эта этот эти всё все весь вся
    есть был была было были будет будут быть стать стал стала стало стали
    делать сделать делаем сделаем сделали сделал сделала надо нужно можно нужен нужна нужны
    сказать говорить сказал сказала знать знаю думать думаю хотеть хочу хотим могу может можем
    смотреть видеть идти пойти взять дать дайте давай давайте проверить проверь посмотреть
    добавить добавь убрать убери написать напиши запустить запусти обновить обнови
    работа работы работу работать работает работают задача задачи задачу задачей
    проект проекта проекте проекту проектом проекты проектов клиент клиента клиенту клиентом
    клиенты клиентов встреча встречи встречу встрече встречей команда команды команду
    вопрос вопросы вопроса ответ ответы решение решения план плана планы итоги итог цель цели
    статус результат результаты описание обзор введение заключение примечание примечания
    содержание оглавление ссылки контакты установка настройка использование требования
    пример примеры шаг шаги раздел глава часть часть список таблица файл файлы папка папки
    система системы данные данных текст текста слово слова время времени год года лет
    человек люди людей дело дела день дня дней неделя недели месяц месяца раз раза
    вариант варианты способ способы причина проблема проблемы идея идеи процесс процесса
    новый новая новое новые старый старая большой большая маленький хороший плохой
    первый первая первое второй вторая третий последний следующий главный основной
    важно важный готово готов готова сделано тест тесты проверка
    """.split()
)

NATURAL = COMMON_EN | COMMON_RU
ALL_COMMON = NATURAL | CODE_COMMON


def is_natural_word(word: str) -> bool:
    """Слово естественного языка (EN или RU) — по форме целиком."""
    return word.casefold() in NATURAL


def is_common(word: str) -> bool:
    """Словарное слово или служебное имя кода."""
    return word.casefold() in ALL_COMMON
