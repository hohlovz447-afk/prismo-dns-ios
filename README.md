<div align="right">

**🇷🇺 Русский** · [🇬🇧 English](README.en.md)

</div>

# Prismo DNS

iOS-клиент Prismo DNS — VPN на основе туннелирования через DNS для сетей с жёсткой цензурой.

Приложение поднимает локальный SOCKS5-прокси на `127.0.0.1:41080` для подключения через сторонние VPN-приложения (Shadowrocket, Happ и т.п.), которые уже пропускают весь системный трафик через DNS-туннель.
Собственный VPN-профиль Prismo создаёт только в том случае, если Вы подписали приложение действительным сертификатом Apple.

## Настройка сервера

**Требования:**
VPS (Ubuntu 22.04+ / Debian 11+) >500MB RAM<br>
Домен с любым TLD (не обязательно .ru), без кириллицы! Чем меньше символов в домене, тем лучше.

1. В панели управления DNS-записями домена создайте:

A-запись **`ns`**, указывающую на Ваш VPS:<br>
`ns.domain.ru` -> `12.34.56.78`

NS-запись **`v`** (обязательно в одну букву!), указывающую на A-запись:<br>
`v.domain.ru` -> `ns.domain.ru`

Если Ваш домен делегирован / создан в Cloudflare, **Proxy status** этих записей должен быть **DNS only** (серое облако).<br>
Если Вы купили домен в другом месте (reg.ru и т.п.), рекомендуется делегировать его на Cloudflare - обновление записей будет происходить намного быстрее.

2. Подключитесь по `ssh` к Вашему VPS и введите:

```
sudo bash && cd
```

```
sudo apt update -y && sudo apt full-upgrade -y && sudo apt install curl -y
```

```
sudo tee /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
EOF
sudo sysctl -p > /dev/null 2>&1
```

```
bash <(curl -Ls <URL-СКРИПТА-УСТАНОВКИ-СЕРВЕРА>)
```

По итогу запуска последней команды Вы получите ключ шифрования. Сохраните его, чтобы не возвращаться к серверу.

## Настройка Prismo DNS

1. Запустите Prismo DNS и нажмите **Импорт**.
2. Введите делегированный домен с вашего сервера (то же значение, что в NS-записи, `v.domain.ru`).
3. Введите ключ шифрования, полученный при настройке сервера.
4. Нажмите **Импорт**, затем кнопку "питания" для запуска туннеля. В настройках профиля **Метод шифрования** должен совпадать со значением `DATA_ENCRYPTION_METHOD` в `server_config.toml` сервера (совпадает по умолчанию, XOR).
5. SOCKS5-прокси запустится на `127.0.0.1:41080`. Откройте Shadowrocket / Happ / и т.п., добавьте SOCKS5-прокси на этот адрес, и подключитесь.

## Структура репозитория

```
prismo-dns-ios/
├── apple/                            # Проект Xcode / SwiftPM
│   ├── Package.swift                 # Общая библиотека PrismoKit
│   ├── project.yml                   # Описание проекта для XcodeGen
│   ├── Frameworks/                   # Сюда падает Mobile.xcframework
│   ├── Scripts/
│   │   ├── build-xcframework.sh         # gomobile bind → Mobile.xcframework
│   │   ├── build-ios-unsigned-local-ipa.sh
│   │   ├── prepare-xcode.sh             # обёртка над xcodegen
│   │   └── generate-icon.py             # генератор AppIcon (Pillow)
│   ├── Sources/
│   │   ├── PrismoApp/                # таргет iOS-приложения
│   │   │   ├── Assets.xcassets/AppIcon.appiconset/
│   │   │   ├── Info.plist            # UIBackgroundModes=[audio]
│   │   │   └── PrismoApp.swift
│   │   └── PrismoKit/                # Общая SwiftPM-библиотека
│   │       ├── Models/               # ConnectionProfile, ClientStatus
│   │       ├── Services/             # TunnelEngine, BackgroundRuntimeKeeper, …
│   │       ├── ViewModels/           # ClientViewModel
│   │       ├── Views/                # ContentView, ImportProfileSheet, …
│   │       └── Resources/{en,ru}.lproj/Localizable.strings
│   └── Tests/PrismoKitTests/
└── engine/                           # Go-ядро DNS-туннеля
    ├── go.mod                        # добавлена зависимость golang.org/x/mobile
    └── mobile/                       # gomobile-обёртка
        ├── mobile.go                 #   Start/Stop/IsRunning/SetLogWriter
        └── stdout_pump.go            #   перенаправляет stdout → LogWriter
```

## Для сборки

- macOS 14 + Xcode 16 (iOS-инструментарий идёт в составе Xcode)
- [Homebrew](https://brew.sh)
- `brew install go xcodegen`
- `go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`
- Python 3 с Pillow (`python3 -m pip install --user pillow`) — только если хотите пересобрать иконку приложения

## Сборка

```bash
# 1. Собираем Go-xcframework
apple/Scripts/build-xcframework.sh

# 2. Генерируем проект Xcode
apple/Scripts/prepare-xcode.sh

# 3. Собираем неподписанный IPA
apple/Scripts/build-ios-unsigned-local-ipa.sh
#   → apple/.build/ios-unsigned-local/PrismoDNS-unsigned.ipa
```

IPA-файл не подписан. Подпишите и установите его на устройство одним из способов:

- **[Sideloadly](https://sideloadly.io)** — перетащите IPA в окно, подпишите своим Apple ID и установите через USB.
- **AltStore / SideStore** — установка прямо на устройстве, после первой настройки Mac уже не нужен.

Перед первой установкой включите на iPhone **Настройки → Конфиденциальность и безопасность → Режим разработчика**.
