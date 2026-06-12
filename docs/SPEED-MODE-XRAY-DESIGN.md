# «Режим Скорость» — встраивание Xray (VLESS) в iOS-приложение

Цель: добавить в приложение второй режим работы — **обычные VLESS-серверы**
(как в Happ): пользователь выбирает страну → нормальная скорость. Текущий
режим (DNS-туннель / «Обход») остаётся для случаев, когда VLESS заблокирован.

---

## 0. Главный вывод (что упрощает задачу в разы)

Бэкенд **уже отдаёт готовую VLESS-подписку**:

```
GET https://prismovpn.org/sub/{token}
  → base64-список vless:// ссылок (default)
  → ?format=singbox  → sing-box JSON
  → (Clash YAML для Happ Pro)
```

Токен — это `referral_code` пользователя (тот же, что для DNS-туннеля он
получает в боте). То есть приложению **не нужно ничего генерить** — оно
фетчит ту же подписку, что v2rayNG/Happ, парсит её и запускает.

Источник: `app/api/webhooks/subscription.py` (`subscription_handler`,
`_build_vless_link`, `_build_cdn_ws_link`).

---

## 1. Архитектура (два движка в одном приложении)

```
            ┌─────────────────────────────────────────┐
            │              Prismo (iOS app)            │
            │                                          │
            │   ┌───────────────┐   ┌──────────────┐   │
            │   │ Режим «Обход» │   │Режим «Скорость│  │
            │   │  DNS-туннель  │   │   VLESS/Xray  │  │
            │   │ (Mobile.xcfw) │   │ (Xray.xcfw)   │  │
            │   └──────┬────────┘   └──────┬───────┘   │
            │          │ SOCKS5            │ SOCKS5     │
            │          └─────────┬─────────┘           │
            │              ┌─────▼──────┐               │
            │              │ tun2socks  │  (NEPacket-   │
            │              │  + NE      │   TunnelProv.)│
            │              └────────────┘               │
            └─────────────────────────────────────────┘
```

Оба движка — это локальные SOCKS5-прокси (DNS-туннель уже так работает).
**Network Extension** (`NEPacketTunnelProvider` + `tun2socks`) поднимает
системный TUN-интерфейс и заворачивает весь трафик в активный SOCKS5.
Это и есть «значок VPN», которого сейчас нет, и системная маршрутизация.

> Это решает обе прошлые жалобы:
> 1. «нет значка VPN» — появится (NE).
> 2. «надо отдельный клиент для маршрутизации» — не надо (tun2socks внутри).

---

## 2. Объём работ (по компонентам)

### 2.1. Xray core как xcframework (Go → gomobile)
- Собрать `xray-core` (или `Xray-core`) в `Xray.xcframework` через gomobile,
  по аналогии с тем, как собран существующий `Mobile.xcframework`
  (см. `apple/Scripts/build-xcframework.sh`).
- Экспортировать `Start(configJSON) / Stop()` + SOCKS-порт.
- Xray умеет VLESS+Reality, VLESS+WS+TLS (CDN), XTLS-vision — всё, что
  уже есть в нашей подписке.

### 2.2. Парсер подписки
- `SubscriptionFetcher`: `GET /sub/{token}` → base64 → список `vless://`.
- `VlessParser`: `vless://uuid@host:port?type=...&security=...&sni=...#NAME`
  → модель `VlessServer { name, host, port, sni, fp, transport, reality... }`.
- Имя сервера (`#fragment`) уже содержит страну/метку — берём для UI.

### 2.3. UI «Скорость»
- Список серверов (страны) из распарсенной подписки.
- Тап → выбрать сервер → собрать Xray config JSON → запустить Xray engine.
- Переключатель режимов «Обход» / «Скорость» на главном экране.

### 2.4. Network Extension (см. отдельный todo)
- `NEPacketTunnelProvider` + встроенный `tun2socks`.
- **Требует платный Apple Developer аккаунт** (capability Packet Tunnel).
- App Group для передачи активного SOCKS-порта/конфига между app и NE.

### 2.5. Конфиг-билдер Xray
- Маппинг `VlessServer` → Xray JSON (inbound: socks 127.0.0.1:port;
  outbound: vless с reality/ws настройками). Сопоставить с тем, что
  генерит сервер (Reality public key, shortId, spiderX и т.п. — они
  приходят в vless-ссылке).

---

## 3. Порядок реализации

1. **Сейчас (без аккаунта, можно делать):**
   - ✅ `VlessServer` (модель) + `VlessSubscriptionService` (парсер `vless://`
     + фетч `GET /sub/{token}`, поддержка base64/raw, фильтрация не-VLESS).
   - ✅ Юнит-тесты парсера (`VlessParserTests`) — Reality/TCP, gRPC, WS-TLS,
     base64-подписка, мусорные строки. Проверяемо на любой ОС.
   - ⏳ UI-список стран (выбор сервера из распарсенной подписки) + переключатель
     режимов «Обход»/«Скорость».
   - ⏳ Движок: решено брать **sing-box (libbox)** — встроенный tun + VLESS/Reality.
     Сборка `*.xcframework` через gomobile, engine Start/Stop. (требует macOS/CI)
2. **После покупки аккаунта:**
   - NEPacketTunnelProvider (libbox tun) → системный VPN для ОБОИХ режимов.
   - Подпись, App Group, профили, TestFlight.

### Решения (приняты по умолчанию, вопросы были пропущены)
- **Движок «Скорость» = sing-box / libbox** (встроенный tun, проще для NE).
- **Источник стран = `#fragment`** из подписки (метки уже есть).
- **Имена модулей PrismoKit/PrismoApp — НЕ трогаем сейчас** (видны только при
  декомпиляции; рефактор требует проверки сборкой на macOS).

---

## 4. Открытые вопросы (нужно решение)

- **Xray vs sing-box core**: sing-box тоже умеет VLESS/Reality и имеет
  готовую mobile-обвязку (`libbox`) + встроенный tun. Может оказаться
  проще, чем xray-core + ручной tun2socks. Кандидат №1 для NE-режима.
- **Где брать список стран**: из `#fragment` подписки (уже есть метки)
  или добавить в бэкенд отдельный JSON со странами/флагами.
- **Реалистичность App Store**: VLESS-VPN в публичном App Store — высокий
  риск отказа; стартуем через TestFlight.
