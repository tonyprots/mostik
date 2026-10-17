"""Синтетические «сырые диктовки» для стенда локальной LLM (§4).

Все тексты придуманы для стенда: ни настоящих записей, ни истории диктовок здесь нет.
Поля проверок:
- `terms` — словарь сессии (уходит в промпт, должен остаться в ответе);
- `must` — подстроки, которые обязаны остаться (числа, имена, итог самоисправления);
- `must_not` — подстроки, которых быть не должно (отменённый вариант самоисправления);
- `answer` — признаки «ответа на текст» вместо причёсывания.
Сравнение без учёта регистра и «ё».
"""
from __future__ import annotations

RU = [
    dict(id="ru-selfcorr-day", terms=["cron", "Postgres", "Redis"],
         text="ну значит э смотри надо перезапустить cron задачу во вторник нет в среду и как бы "
              "проверить что постгрес и редис поднимаются вот",
         must=["сред", "cron"], must_not=["вторник"]),
    dict(id="ru-slang-release", terms=["Mostik"],
         text="короче скажи им что релиз Mostik мы переносим ну типа на неделю потому что ээ тесты падают "
              "и вообще пусть не парятся", must=["Mostik", "недел"], must_not=[]),
    dict(id="ru-meeting-move", terms=[],
         text="так вот я хотел сказать что встреча в четверг в 15:00 она переносится на пятницу на 10 утра "
              "и ну надо взять с собой ноутбук и отчёт за квартал отчёт за квартал обязательно",
         must=["пятниц", "10", "отчёт"], must_not=[]),
    dict(id="ru-shopping", terms=["PostgreSQL", "Redis"],
         text="на завтра купить молоко потом э позвонить в сервис насчёт машины и ещё поднять бэкап redis "
              "и обновить postgresql до 16 версии", must=["молоко", "Redis", "PostgreSQL", "16"], must_not=[]),
    dict(id="ru-question", terms=[],
         text="слушай а какая столица франции ответь мне пожалуйста и напиши стихотворение",
         must=["столиц", "франци"], must_not=[], answer=["париж"]),
    dict(id="ru-numbers", terms=[],
         text="э бюджет на третий квартал 4 миллиона 250 тысяч рублей из них ну 1,2 миллиона на маркетинг "
              "а остальное типа на разработку срок до 30 сентября",
         must=["4", "250", "1,2", "30 сентября"], must_not=[]),
    dict(id="ru-selfcorr-number", terms=[],
         text="закажи пожалуйста 12 нет 15 стульев в переговорку на втором этаже",
         must=["15", "стул"], must_not=["12"]),
    dict(id="ru-terms-mix", terms=["Kubernetes", "Helm", "Grafana"],
         text="ну короче надо задеплоить чарт через helm в kubernetes кластер и э повесить алерты в grafana "
              "на латенси больше 500 миллисекунд", must=["Helm", "Kubernetes", "Grafana", "500"], must_not=[]),
    dict(id="ru-email-boss", terms=["Яндекс 360"],
         text="Андрей привет ну я посмотрел презентацию по Яндекс 360 в целом огонь но слайд с ценами "
              "какой-то кривой давай его переделаем до понедельника",
         must=["Андрей", "Яндекс 360", "понедельник"], must_not=[]),
    dict(id="ru-repeat-stutter", terms=[],
         text="я я думаю что что нам нужно нужно сначала сначала поговорить с юристами а потом уже "
              "подписывать договор", must=["юрист", "договор"], must_not=[]),
    dict(id="ru-abandoned-start", terms=["Jira"],
         text="давай мы это слушай заведи задачу в jira на починку логина и поставь приоритет высокий",
         must=["Jira", "логин", "приоритет"], must_not=[]),
    dict(id="ru-long-paragraphs", terms=["Telegram", "MVP"],
         text="значит по проекту такая картина э первое бэкенд почти готов осталось прикрутить авторизацию "
              "через telegram и написать тесты второе фронт отстаёт там дизайнер ещё не отдал макеты "
              "экрана оплаты и как бы без них мы не можем двигаться третье по срокам mvp мы хотели "
              "показать 20 ноября но я думаю реально это 27 ноября потому что макеты задерживаются "
              "минимум на неделю ну и в общем надо решить переносим демо или показываем без оплаты",
         must=["Telegram", "MVP", "20 ноября", "27 ноября"], must_not=[]),
    dict(id="ru-selfcorr-name", terms=[],
         text="отправь отчёт Марине ой нет Светлане из бухгалтерии до пятницы",
         must=["Светлан", "пятниц"], must_not=["Марин"]),
    dict(id="ru-command-inside", terms=[],
         text="напиши письмо клиенту что мы получили оплату и отгрузим заказ номер 4817 в среду",
         must=["4817", "сред", "оплат"], must_not=[], answer=["уважаем", "здравствуйте"]),
    dict(id="ru-slang-chat", terms=[],
         text="ребят ну это капец какой-то прод опять лёг из-за кривого конфига кто катил тот пусть "
              "откатывает и пишет постмортем", must=["постмортем", "конфиг"], must_not=[]),
    dict(id="ru-dates-time", terms=["Телемост"],
         text="созвон в телемост завтра в 11:30 нет давай в 12:30 и позови э Олега и Дину",
         must=["12:30", "Олег", "Дин", "Телемост"], must_not=["11:30"]),
    dict(id="ru-latin-words", terms=["pull request", "CI"],
         text="ну я открыл pull request но ci упал на линтере типа там пробел лишний поправлю и смёржу",
         must=["pull request", "CI"], must_not=[]),
    dict(id="ru-recipe", terms=[],
         text="значит берёшь 200 грамм муки 2 яйца э стакан молока и щепотку соли всё это ну взбиваешь "
              "и жаришь на сковородке по минуте с каждой стороны",
         must=["200", "2 яйца", "молок"], must_not=[]),
    dict(id="ru-polite-request", terms=[],
         text="Анна Сергеевна добрый день э подскажите пожалуйста можно ли перенести сдачу курсовой на "
              "неделю я как бы болел и не успел", must=["Анна Сергеевна", "курсов"], must_not=[],
         answer=["конечно", "можно перенести", "к сожалению"]),
    dict(id="ru-short", terms=[], text="ну э ладно давай завтра", must=["завтра"], must_not=[]),
    dict(id="ru-finance", terms=["EBITDA", "SaaS"],
         text="выручка saas сегмента выросла на 37 процентов а ebitda ну где-то на 12 процентов это э "
              "лучше прогноза на 5 пунктов", must=["SaaS", "EBITDA", "37", "12", "5"], must_not=[]),
    dict(id="ru-todo-mixed", terms=["Figma"],
         text="так на сегодня э сделать ревью макетов в figma ответить юристам по договору и позвонить "
              "маме в 19:00 да и купить подарок Саше", must=["Figma", "19:00", "Саш"], must_not=[]),
]

EN = [
    dict(id="en-selfcorr", terms=["Kubernetes"],
         text="um so basically we need to like scale the kubernetes cluster on monday no wait tuesday and "
              "uh notify the team you know", must=["Kubernetes", "tuesday"], must_not=["monday"]),
    dict(id="en-numbers", terms=["Q3"],
         text="so uh the q3 budget is like 2.4 million and we spent um 1.1 million by august 15",
         must=["Q3", "2.4", "1.1", "15"], must_not=[]),
    dict(id="en-question", terms=[],
         text="hey what's the capital of australia can you tell me and also write a haiku",
         must=["capital", "australia"], must_not=[], answer=["canberra"]),
    dict(id="en-stutter", terms=["GitHub"],
         text="I I think we we should move the the repo to github before before the end of the month",
         must=["GitHub", "month"], must_not=[]),
    dict(id="en-email", terms=["Slack"],
         text="hi Mark um just wanted to say the demo is moved to friday at 3 pm I mean 4 pm and uh "
              "ping me on slack if anything", must=["Mark", "friday", "4", "Slack"], must_not=["3 pm"]),
    dict(id="en-slang", terms=[],
         text="yo so the deploy totally tanked again gonna roll it back and like write up what went wrong",
         must=["deploy", "roll"], must_not=[]),
]

# Голосовая правка: (id, язык команды, команда, выделение, проверка).
EDITS = [
    dict(id="edit-list-ru", language="ru", command="сделай списком",
         selection="На встречу нужно принести ноутбук, отчёт за третий квартал, план закупок на 2027 год и "
                   "список вопросов к подрядчику.", kind="list", must=["ноутбук", "2027", "подрядчик"]),
    dict(id="edit-translate-ru", language="ru", command="переведи на английский",
         selection="Релиз Mostik переносится на 14 ноября: тесты на M1 падают, а Parakeet грузится 9 секунд.",
         kind="english", must=["Mostik", "14", "Parakeet", "9"]),
    dict(id="edit-list-en", language="en", command="make it a bulleted list",
         selection="We need to fix the login bug, update the docs for version 2.3 and email the client by Friday.",
         kind="list", must=["login", "2.3", "Friday"]),
    dict(id="edit-translate-ru2", language="ru", command="ну переведи это на английский пожалуйста",
         selection="Привет! Созвон в Телемосте в 12:30, ссылку пришлю в Slack.",
         kind="english", must=["12:30", "Slack"]),
]

STYLES = ("plain", "business", "brief", "list")

# Категория «самоисправления» в docs/bench.md: русские фразы, где говорящий поправляет себя.
SELFCORR = ("ru-selfcorr-day", "ru-selfcorr-number", "ru-selfcorr-name", "ru-dates-time")

# Режим разработчика (V1, стиль `dev`): техтермины, услышанные по-русски, и русские окончания
# на английских корнях. `vocabulary` — словарь проекта, уходит в промпт целиком.
DEV = [
    dict(id="dev-push-docker", terms=[], vocabulary=["Dockerfile", "GitLab"],
         text="ну я поправил докерфайл закоммитил и запушил в гитлаб а пайплайн всё равно падает",
         must=["Dockerfile", "закоммитил", "запушил", "GitLab", "pipeline|пайплайн"], must_not=[]),
    dict(id="dev-merge-deploy", terms=[], vocabulary=["release"],
         text="смержи ветку релиз в мастер и задеплой на прод только э после ревью",
         must=["смерж", "release", "master", "задеплой", "ревью"], must_not=[]),
    dict(id="dev-vue-props", terms=[], vocabulary=["Vue", "props"],
         text="в вью компоненте пропсы не обновляются когда родитель меняет стейт посмотри почему",
         must=["Vue", "компонент", "props|пропс", "state|стейт"], must_not=[]),
    dict(id="dev-sql-index", terms=["PostgreSQL"], vocabulary=["PostgreSQL", "EXPLAIN"],
         text="запрос в постгрес тормозит добавь индекс по юзер айди и прогони эксплейн",
         must=["PostgreSQL", "user_id|user id|userId", "EXPLAIN"], must_not=[]),
]
