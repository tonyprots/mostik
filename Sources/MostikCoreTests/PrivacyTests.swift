import Foundation
import MostikCore

/// Приватность: облачное согласие встреч, «чувствительные» встречи, поле consent в командах движка.
func runPrivacyTests() {
    // Главный сценарий: согласие дано при локальной модели → бэкенд сменили на Claude → облако закрыто.
    do {
        var s = MostikSettings()
        check(!s.meetingAICloudConsent, "облачное согласие по умолчанию выключено")
        s.polish.backend = .mlx
        s.grantMeetingAI()
        check(s.meetingAIConsent && !s.meetingAICloudConsent, "при локальной модели облачное согласие не ставится")
        equal(MeetingAIPolicy.gate(s), .ready(.mlx))
        var next = s
        next.polish.backend = .claude
        next.polish.cloudConsent = true  // согласие на причёсывание дано — встречам его мало
        next = MeetingCloudPolicy.reconcile(old: s, new: next)
        check(!MeetingCloudPolicy.cloudAllowed(next), "облако закрыто после смены бэкенда")
        equal(MeetingAIPolicy.gate(next), .needsConsent(.claude), "сводка просит своё согласие")
        check(!MeetingAIPolicy.autoRun(next), "сама не запускается")
        equal(CloudGrants(settings: next).meetings, false)
    }

    // Облачное согласие сбрасывается при любой смене бэкенда, даже туда и обратно.
    do {
        var s = MostikSettings()
        s.polish = PolishSettings(backend: .claude, cloudConsent: true)
        s.grantMeetingAI()
        check(MeetingCloudPolicy.cloudAllowed(s), "согласие с экрана при Claude открывает облако")
        equal(MeetingAIPolicy.gate(s), .ready(.claude))
        var local = s
        local.polish.backend = .mlx
        local = MeetingCloudPolicy.reconcile(old: s, new: local)
        check(!local.meetingAICloudConsent, "claude → mlx: сброшено")
        check(local.meetingAIConsent, "локальное согласие остаётся")
        var back = local
        back.polish.backend = .claude
        back = MeetingCloudPolicy.reconcile(old: local, new: back)
        check(!MeetingCloudPolicy.cloudAllowed(back), "mlx → claude: спросить снова")
        // Отзыв облачного согласия причёсывания — тоже смена действующего бэкенда.
        var revoked = s
        revoked.polish.cloudConsent = false
        revoked = MeetingCloudPolicy.reconcile(old: s, new: revoked)
        check(!revoked.meetingAICloudConsent, "отзыв согласия причёсывания сбрасывает и встречи")
        // Без смены бэкенда (выдача согласия одним обновлением) — не сбрасывается.
        var same = s
        same.language = "en"
        check(MeetingCloudPolicy.reconcile(old: s, new: same).meetingAICloudConsent, "другие настройки не трогают")
        // Выключили «Заметки и сводку» — облачное согласие уходит вместе с общим.
        var off = s
        off.meetingAIConsent = false
        check(!MeetingCloudPolicy.reconcile(old: s, new: off).meetingAICloudConsent)
    }

    // Старый файл настроек: meetingAIConsent при Claude больше не открывает облако.
    do {
        let json = #"{"meetingAIConsent": true, "polish": {"backend": "claude", "cloudConsent": true, "cloudConsentFor": "claude@v1"}}"#
        let s = try! JSONDecoder().decode(MostikSettings.self, from: Data(json.utf8))
        check(!s.meetingAICloudConsent)
        equal(MeetingAIPolicy.gate(s), .needsConsent(.claude), "после обновления спросим заново")
        let saved = try! JSONEncoder().encode(MostikSettings())
        check(String(decoding: saved, as: UTF8.self).contains("meetingAICloudConsent"), "поле сохраняется")
    }

    // Переключатель в Настройках сам облачного согласия не ставит — только открывает экран.
    do {
        var s = MostikSettings()
        s.polish = PolishSettings(backend: .claude, cloudConsent: true)
        check(!MeetingCloudPolicy.toggleIsOn(s))
        equal(MeetingCloudPolicy.toggle(true, settings: s), .askCloudConsent, "при Claude — экран согласия")
        s.meetingAIConsent = true  // старое общее согласие
        check(!MeetingCloudPolicy.toggleIsOn(s), "без облачного переключатель выключен")
        equal(MeetingCloudPolicy.toggle(true, settings: s), .askCloudConsent)
        s.grantMeetingAI()
        check(MeetingCloudPolicy.toggleIsOn(s))
        if case .apply(let off) = MeetingCloudPolicy.toggle(false, settings: s) {
            check(!off.meetingAIConsent && !off.meetingAICloudConsent, "выключение снимает оба согласия")
        } else { check(false, "выключение применяется сразу") }
        var local = MostikSettings()
        local.polish.backend = .mlx
        if case .apply(let on) = MeetingCloudPolicy.toggle(true, settings: local) {
            check(on.meetingAIConsent && !on.meetingAICloudConsent, "локальная модель — без экрана, без облака")
        } else { check(false, "локальная модель включается сразу") }
    }

    // Своя модель встреч: диктовка выключена, встречи на этом Mac; смена диктовки встречи не трогает.
    do {
        var s = MostikSettings()
        s.meetingBackend = .mlx
        s.grantMeetingAI()
        equal(s.polish.effectiveBackend, .off)
        equal(MeetingAIPolicy.gate(s), .ready(.mlx), "встречи на своей модели")
        equal(MeetingCloudPolicy.backend(s), .mlx)
        var next = s
        next.polish.backend = .claude
        next.polish.cloudConsent = true
        equal(next.meetingEffectiveBackend, .mlx, "диктовка на Claude, встречи остались на этом Mac")
    }

    // Согласие на облако встреч, данное тем же действием, что выбрало Claude (онбординг), не сбрасывается;
    // данное раньше — сбрасывается при смене модели.
    do {
        let old = MostikSettings()
        var chosen = old
        chosen.polish.backend = .claude
        chosen.polish.cloudConsent = true
        chosen.grantMeetingAI()
        let kept = MeetingCloudPolicy.reconcile(old: old, new: chosen)
        check(kept.meetingAICloudConsent, "согласие из онбординга остаётся")
        equal(MeetingAIPolicy.gate(kept), .ready(.claude))
        var local = kept
        local.polish.backend = .mlx
        check(!MeetingCloudPolicy.reconcile(old: kept, new: local).meetingAICloudConsent, "сменили модель — облако закрыто")
        var split = kept
        split.meetingBackend = .claude
        split.polish.backend = .off
        check(MeetingCloudPolicy.reconcile(old: kept, new: split).meetingAICloudConsent,
              "встречи остались на Claude — согласие не теряется")
    }

    // «Чувствительная» встреча закрыта для облака, локальной модели — открыта.
    do {
        var s = MostikSettings()
        s.polish = PolishSettings(backend: .claude, cloudConsent: true)
        s.grantMeetingAI()
        equal(MeetingAIPolicy.gate(s, sensitive: true), .sensitiveCloud)
        check(!MeetingAIPolicy.autoRun(s, sensitive: true), "сводка сама не уходит")
        equal(MeetingCloudPolicy.backend(s, sensitive: true), .off)
        equal(MeetingCloudPolicy.backend(s), .claude)
        // Локальная модель скачана — сводка и название уходят на неё, сами, без облака.
        equal(MeetingAIPolicy.gate(s, sensitive: true, localModel: true), .ready(.mlx))
        check(MeetingAIPolicy.autoRun(s, sensitive: true, localModel: true), "локальная сводка запускается сама")
        equal(MeetingAIPolicy.gate(s, localModel: true), .ready(.claude), "обычная встреча остаётся на Claude")
        s.polish.backend = .mlx
        equal(MeetingAIPolicy.gate(s, sensitive: true), .ready(.mlx), "на этом Mac — можно")
    }

    // Поле consent: только для облачной команды и только при действующем согласии на этот вид данных.
    do {
        let none = CloudGrants()
        let all = CloudGrants(dictation: true, meetings: true)
        let summary: [String: JSONValue] = ["folder": .string("/m"), "backend": .string("claude")]
        equal(CloudConsentStamp.stamp("meeting_ai", fields: summary, grants: none)["consent"], .bool(false))
        equal(CloudConsentStamp.stamp("meeting_ai", fields: summary, grants: all)["consent"], .bool(true))
        equal(CloudConsentStamp.stamp("meeting_ai", fields: summary, grants: CloudGrants(dictation: true))["consent"],
              .bool(false), "согласие диктовки не открывает встречи")
        let local: [String: JSONValue] = ["backend": .string("mlx")]
        check(CloudConsentStamp.stamp("meeting_ai", fields: local, grants: all)["consent"] == nil, "локальную не трогаем")
        let start: [String: JSONValue] = ["polish": .object(["backend": .string("claude"), "style": .string("plain")])]
        equal(CloudConsentStamp.stamp("start", fields: start, grants: CloudGrants(dictation: true))["consent"], .bool(true))
        equal(CloudConsentStamp.stamp("start", fields: start, grants: CloudGrants(meetings: true))["consent"], .bool(false))
        // Команда передаёт своё согласие; облачный штамп может только сузить его.
        let own: [String: JSONValue] = ["backend": .string("claude"), "consent": .bool(false)]
        equal(CloudConsentStamp.stamp("meeting_hint", fields: own, grants: all)["consent"], .bool(false))
        equal(CloudConsentStamp.stamp("unknown_cmd", fields: summary, grants: all)["consent"], .bool(false),
              "неизвестной команде облака не даём")
        // Все облачные пути приложения получают поле при действующем согласии.
        for cmd in ["start", "transcribe_file", "polish_text", "edit", "intent"] {
            equal(CloudConsentStamp.stamp(cmd, fields: summary, grants: CloudGrants(dictation: true))["consent"], .bool(true), cmd)
        }
        for cmd in ["meeting_ai", "meeting_recipe", "archive_brief"] {
            equal(CloudConsentStamp.stamp(cmd, fields: summary, grants: CloudGrants(meetings: true))["consent"], .bool(true), cmd)
        }
        let line = EngineCodec.command("edit", id: 1, fields: CloudConsentStamp.stamp("edit", fields: summary, grants: all))
        check(line.contains(#""consent":true"#), "поле уходит в строку команды")
    }
}

/// П. 5 и 8: окружение движка офлайн, адреса из окружения — только в debug-сборке.
func runPrivacyEnvironmentTests() {
    var env = ["PATH": "/usr/bin", "HF_HUB_OFFLINE": "0", "MOSTIK_MODELS_BASE_URL": "https://mirror.example.net"]
    EngineEnvironment.apply(to: &env)
    equal(env["HF_HUB_OFFLINE"], "1", "офлайн поверх пользовательского значения")
    equal(env["HF_HUB_DISABLE_TELEMETRY"], "1")
    equal(env["TRANSCRIBER_NO_UPDATE_CHECK"], "1", "проверка обновлений transcriber выключена и без --offline")
    check(env["MOSTIK_MODELS_BASE_URL"] == nil, "адрес моделей движок из окружения не получает")
    equal(env["PATH"], "/usr/bin")

    let mirror = ["MOSTIK_MODELS_BASE_URL": "http://127.0.0.1:8000"]
    equal(DebugOverrides.modelsBaseURL(environment: mirror, debug: true), "http://127.0.0.1:8000")
    check(DebugOverrides.modelsBaseURL(environment: mirror, debug: false) == nil, "в выпуске окружение не действует")
    check(DebugOverrides.modelsBaseURL(environment: ["MOSTIK_MODELS_BASE_URL": "file:///etc"], debug: true) == nil)
    check(DebugOverrides.modelsBaseURL(environment: [:], debug: true) == nil)
}

/// П. 6: правка голосом в исключённых приложениях выделение не читает и никуда не шлёт.
func runVoiceEditExclusionTests() {
    var probed = 0
    func probe() -> SelectionProbe { probed += 1; return .text("пароль от банка") }
    let context = PolishContextSettings(excludedApps: ["com.example.secret"])
    for bundle in ["com.1password.1password", "com.apple.keychainaccess", "com.example.secret"] {
        let excluded = VoiceEditSelection.isExcluded(bundleID: bundle, settings: context)
        check(excluded, bundle)
        equal(VoiceEditSelection.plan(probe: probe(), secureInput: false, excludedApp: excluded), .refuse(.excludedApp), bundle)
    }
    equal(probed, 0, "выделение в исключённом приложении не читается")
    check(!VoiceEditSelection.isExcluded(bundleID: "com.apple.TextEdit", settings: context))
    equal(VoiceEditSelection.plan(probe: probe(), secureInput: false, excludedApp: false), .use("пароль от банка"))
    equal(probed, 1)
    equal(VoiceEditSelection.plan(probe: probe(), secureInput: true), .refuse(.secureInput))
    equal(probed, 1, "в защищённом поле — тоже не читается")
}

/// П. 3: календарь и агенты — участники в хук только по явной опции, тексты не обещают лишнего.
func runCalendarAgentPrivacyTests() {
    check(!AgentContextSettings().includeAttendees, "участники встречи агенту по умолчанию не идут")
    let old = try! JSONDecoder().decode(AgentContextSettings.self, from: Data(#"{"hookEnabled": true}"#.utf8))
    check(!old.includeAttendees, "старый файл настроек — без участников")
    var on = AgentContextSettings()
    on.includeAttendees = true
    let json = String(decoding: try! JSONEncoder().encode(on), as: UTF8.self)
    check(json.contains(#""includeAttendees":true"#), "ключ, который читает движок (agent_api.HOOK_DEFAULTS)")

    // Лист установки прямо говорит, что уходит и что агент отправляет в облако.
    let saved = UIText.isRussian
    for ru in [true, false] {
        UIText.isRussian = ru
        let off = AgentIntegration.privacyNotice(includeAttendees: false)
        let with = AgentIntegration.privacyNotice(includeAttendees: true)
        check(off != with)
        for text in [off, with] {
            check(text.contains(ru ? "облако" : "cloud") && text.contains("Anthropic"), "про облако агента: \(text)")
            check(text.contains(ru ? "название" : "title"), "про название встречи")
        }
        check(off.contains(ru ? "не передаются" : "not sent"), "без участников так и сказано")
        let plan = AgentIntegration.plan(.claudeCode, home: URL(fileURLWithPath: "/h"), cliPath: "/m", skill: "x")
        let hook = plan.steps.first { $0.kind == .mergeHook }?.summary ?? ""
        check(hook.contains(ru ? "название встречи" : "title of a meeting"), "шаг хука: \(hook)")
    }
    UIText.isRussian = saved

    // Info.plist: текст доступа к календарю не обещает «никуда не отправляется» и говорит про агента.
    let plistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    if let data = try? Data(contentsOf: plistURL),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let text = plist["NSCalendarsFullAccessUsageDescription"] as? String {
        check(!text.contains("никуда не отправляется"), "старое обещание снято")
        check(text.contains("агент") && text.contains("MCP") && text.contains("облако"), "честно про хук и MCP")
        check(text.contains("участников — только если вы это включите"))
    } else {
        check(false, "NSCalendarsFullAccessUsageDescription не прочитан")
    }
}
