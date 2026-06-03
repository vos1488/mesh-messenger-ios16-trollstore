# MeshWave (iOS 16+, TrollStore/ESign)

Децентрализованный P2P-мессенджер без центральных серверов.  
Каждое устройство работает как самостоятельный узел mesh-сети: находит пиров, передаёт сообщения, может быть relay-узлом и хранит данные локально.

## Что умеет сейчас

- P2P discovery (Multipeer Connectivity)
- Личные чаты с локальным хранением (SQLite)
- E2EE: Double Ratchet + Ed25519 + X25519 + AES-256-GCM
- Store-and-forward (очередь и повторная доставка)
- Mesh relay / базовая маршрутизация
- Голосовые звонки (WebRTC/MC stream pipeline)
- Передача файлов чанками
- Автообновления через GitHub Releases
  - TrollStore: установка через `apple-magnifier://install`
  - ESign/GBox: скачивание IPA и share sheet

## Как это работает

1. При первом запуске генерируются ключи и `peer://` идентификатор.
2. Узел публикует свой профиль в локальной сети.
3. При обнаружении пиров строятся маршруты и синхронизируются известные данные.
4. Сообщения шифруются на стороне отправителя и передаются hop-by-hop.
5. Если получатель офлайн, сообщение остаётся в очереди и доставляется позже.

## Установка

### TrollStore
1. Скачайте `.ipa` из [Releases](../../releases).
2. Откройте в TrollStore и установите.

### ESign / GBox
1. Скачайте `.ipa` из [Releases](../../releases).
2. Импортируйте через меню «Поделиться» в ESign/GBox.

## Обновления

- Источник: `https://api.github.com/repos/vos1488/mesh-messenger-ios16-trollstore/releases/latest`
- Для **публичного** репозитория GitHub token не нужен.
- Token нужен только для приватного форка.

## Разработка

Требования:
- Xcode 16+
- iOS 16 SDK+

Быстрый старт:

```bash
xcodegen generate
```

Сборка IPA выполняется GitHub Actions workflow (`Build IPA (TrollStore)`).

### Web companion + PC peer service (Go)

В `web-go` добавлен desktop peer service с запуском как обычный процесс и как системный сервис.
Новый web-клиент выполнен в стиле desktop messenger (Liquid Glass UI), показывает live-события сессии и проверяет криптографическое подтверждение узла:

- `auth_challenge` + `auth_signature` (Ed25519) для handshake
- fingerprint ключей в web UI
- bridge работает как blind relay (без дешифрования контента)

Быстрый запуск:

```bash
cd web-go
go run . --addr :8080
```

Управление как сервисом:

```bash
cd web-go
go run . --service install
go run . --service start
go run . --service stop
go run . --service uninstall
```

## Roadmap

См. [ROADMAP.md](ROADMAP.md).
