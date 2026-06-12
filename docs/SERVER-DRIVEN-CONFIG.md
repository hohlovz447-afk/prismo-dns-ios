# Server-driven configuration (всё на сервере)

Цель: приложение — «тонкий клиент». Никаких зашитых DNS/серверов и никакой
зависимости от чужих репозиториев. Вся конфигурация приходит с нашего
бэкенда; изменения применяются без пересборки приложения.

## Что теперь где

| Данные | Источник | Endpoint |
|---|---|---|
| VLESS-серверы (режим «Скорость») | бэкенд | `GET /sub/{token}` |
| DNS-туннель: домен, ключ, MTU/ARQ | бэкенд | `GET /api/dns-tunnel/verify/{token}` |
| Резолверы по операторам + fast/yandex | бэкенд | `GET /api/app-config` |
| Список операторов в Settings | из `/api/app-config` | — |

Зашитого больше нет. Удалена зависимость от `hub.mos.ru/pete9/prismo`.

## Бэкенд: `/api/app-config`

`app/api/webhooks/dns_tunnel_api.py`:
- Единый источник истины — `RESOLVER_CARRIERS` (оператор → MCC/MNC + DNS),
  плюс `RESOLVERS_FAST`, `RESOLVERS_YANDEX`, `RESOLVERS_RU_EXTRA`.
- И `verify`, и `app-config` берут резолверы отсюда (`_all_resolvers()`),
  так что списки не расходятся.
- Ответ публичный (без токена, секретов нет), кешируется (`max-age=3600`),
  версионируется (`APP_CONFIG_VERSION`).

Пример ответа:
```json
{
  "version": 1,
  "carriers": [
    {"id":"mts","name":"МТС","mcc_mnc":["25001"],"resolvers":["213.87.0.1", "..."]},
    ...
  ],
  "fast":   ["1.1.1.1","8.8.8.8", "..."],
  "yandex": ["77.88.8.8", "..."],
  "all":    ["...полный объединённый список..."]
}
```

Чтобы поменять резолверы у всех клиентов — правим списки в
`dns_tunnel_api.py`, бампаем `APP_CONFIG_VERSION`, деплоим. Пересборка
приложения НЕ нужна.

## iOS: как клиент это потребляет

- `AppConfigCatalog` (модель) + `AppConfigService` (фетч + кеш на диск +
  bundled-fallback). `current()` — синхронно лучший доступный каталог;
  `refresh()` — фоновое обновление (вызывается в `ClientViewModel.init`).
- `CarrierDetector` (CoreTelephony) определяет активный PLMN (MCC+MNC) и
  выбирает список резолверов: оператор → иначе Yandex → иначе all.
- `ResolverListService.resolve()`:
  1. ручной список (Settings) — если задан;
  2. иначе fast (если включено) из каталога;
  3. иначе оператор, закреплённый в Settings;
  4. иначе авто-определение оператора → его резолверы.
- `ResolverCatalog` теперь просто проекция операторов из каталога (для
  пикера в Settings), без хардкода и без чужого URL.

Fallback-цепочка надёжности: сервер → кеш на диске → bundled-fallback
(Yandex-first), так что туннель работает даже офлайн при первом запуске.

## TODO / на будущее
- Android-клиент может использовать тот же `/api/app-config`
  (TelephonyManager для PLMN).
- Можно добавить в каталог список стран/серверов для UI «Скорость»
  (сейчас страны берутся из `#fragment` подписки).
- Удалить мёртвый `NetworkResolverTextFetcher` в `ResolverListService`
  (остался от старой схемы; не используется).
