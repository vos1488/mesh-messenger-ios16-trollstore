# Roadmap

Ниже — расширенный план развития MeshWave.  
Каждый этап содержит 10–15 конкретных задач.

## Stage 1 — Core stabilization (v1.3)

- [x] Убрать редкие race-condition в call signaling при фоне/форграунде
- [x] Дожать стабильность `MCStreamCallEngine` под длительные звонки (30+ мин)
- [x] Закрыть edge-cases дублей чатов после перезапуска узла
- [x] Доработать дедупликацию peer-списка на уровне памяти и SQLite
- [x] Единая логика retry/backoff для исходящих сообщений и файлов
- [x] Улучшить обработку ACK/read-receipt при временной потере маршрута
- [x] Добавить recovery outbox после crash/kill процесса
- [x] Унифицировать ошибки сети и крипто-ошибки в UI-диагностике
- [x] Добавить ограничение роста in-memory буферов и очередей
- [x] Оптимизировать cold start и старт discovery без пиков CPU
- [x] Добавить smoke-check при старте (база, ключи, транспорт, update-check)
- [x] Протестировать стабильность на iOS 16.0–16.7 и iOS 17/18

## Stage 2 — Messaging UX & chat management (v1.4)

- [x] Ввести чат-настройки: mute, pin, archive, mark unread
- [x] Добавить массовую очистку: «Очистить все чаты»
- [x] Добавить удаление отдельного сообщения у себя (local delete)
- [x] Добавить batched preload истории при скролле вверх (pagination)
- [x] Улучшить поиск по сообщениям (фразы, фильтры, дата/тип)
- [x] Реализовать цитирование (reply-to message)
- [x] Реализовать пересылку сообщений между диалогами
- [x] Добавить индикатор «печатает…» и online-presence heartbeat
- [x] Добавить индикатор прогресса отправки файлов в bubble
- [x] Внедрить единый UI статусов доставки: queued/sent/delivered/read/failed
- [x] Добавить «jump to first unread» в длинных диалогах
- [x] Перенести чаты в tab-navigation (основная вкладка)
- [x] Добавить вкладку карты с trusted геопозицией
- [x] Подготовить визуальный стиль Liquid Glass для ключевых экранов
- [ ] Добавить управление автоудалением истории (retention policy)

## Stage 3 — Groups and secure multiparty chat (v1.5)

- [ ] Добавить модель группы (group_id, owner, role, members)
- [ ] Добавить создание/удаление группы и приглашения по peerID/QR
- [ ] Роли: owner/admin/member + базовые permissions
- [ ] Системные события группы (join/leave/kick/role change)
- [ ] Group sender keys для эффективного шифрования групповых сообщений
- [ ] Ротация group keys при изменении состава участников
- [ ] Защита от replay в групповых сообщениях
- [ ] Дедупликация групповых пакетов по message_id + source route
- [ ] ACK/read-механика для групп (пер-участник и агрегированный статус)
- [ ] Групповой file sharing с перезапросом потерянных чанков
- [ ] Экспорт/импорт параметров группы (без приватных ключей)
- [ ] UI: список участников, статусы, управление ролями

## Stage 4 — Routing, DHT and relay intelligence (v1.6)

- [ ] Тюнинг Kademlia buckets и refresh-политики
- [ ] Peer scoring (latency, delivery ratio, uptime)
- [ ] Улучшенный выбор next-hop на основе score + RTT
- [ ] Circuit-breaker для нестабильных relay-узлов
- [ ] Быстрый failover маршрута при таймаутах hop
- [ ] Route cache с TTL и background revalidation
- [ ] Anti-loop защита через маршрутные отпечатки
- [ ] Адаптивный TTL в зависимости от типа пакета
- [ ] Сжатие route-announcements и sync payload
- [ ] Профили маршрутизации: low-latency / balanced / battery-save
- [ ] Улучшить WAN bootstrap relay onboarding flow
- [ ] Визуализация качества маршрутов в topology view

## Stage 5 — Files, media and reliability (v1.7)

- [ ] Полноценный resume transfer после разрыва/перезапуска
- [ ] Параллельная доставка чанков с adaptive concurrency
- [ ] Контроль целостности chunk-level и file-level checksum
- [ ] Автоперезапрос повреждённых/пропущенных чанков
- [ ] Приоритизация маленьких файлов при загруженной сети
- [ ] Ограничение скорости upload/download per peer
- [ ] Фоновая догрузка файлов на iOS с безопасными лимитами
- [ ] Предпросмотр изображений/видео перед отправкой
- [ ] Сжатие медиа с выбором качества перед отправкой
- [ ] Пауза/продолжение/отмена transfer из UI
- [ ] История трансферов с диагностикой ошибок по каждому файлу
- [ ] Хранилище файлов с автоматической очисткой временных артефактов

## Stage 6 — Calls and realtime communication (v1.8)

- [ ] Улучшить соединение звонка при слабом сигнале и roaming
- [ ] Adaptive bitrate и jitter-buffer tuning для голоса
- [ ] Улучшить echo cancellation и noise suppression пресеты
- [ ] Повторное подключение звонка без сброса сессии
- [ ] Индикация качества звонка (MOS-like UI)
- [ ] Переключение audio route (speaker/earpiece/Bluetooth)
- [ ] Push-to-talk режим для нестабильных сетей
- [ ] Мини-плеер активного звонка поверх навигации
- [ ] Подготовка SDP/ICE абстракции под будущие видео-звонки
- [ ] Базовые групповые voice rooms (alpha)
- [ ] Улучшенные diagnostics логи для call setup фаз
- [ ] Нагрузочное тестирование 1:1 звонков на разных устройствах

## Stage 7 — Security hardening and trust model (v1.9)

- [ ] Trust-on-first-use экран подтверждения ключа
- [ ] Верификация контакта по QR/fingerprint comparison
- [ ] Детект изменения ключа и явные trust warnings
- [ ] Защищённый re-keying протокол для peer sessions
- [ ] Ротация session keys по времени/количеству сообщений
- [ ] Защита от downgrade на уровне capability negotiation
- [ ] Шифрование локальных вложений «at rest»
- [ ] PIN/biometric lock приложения
- [ ] Экспорт зашифрованного backup профиля/ключей
- [ ] Отдельные политики приватности логов и диагностики
- [ ] Security checklist и периодический self-audit
- [ ] Threat model документирование по компонентам

## Stage 8 — Platform expansion and ecosystem (v2.0+)

- [ ] Полноценные видео-звонки (H264/HEVC/VP8)
- [ ] Screen sharing для 1:1 и групповых сессий
- [ ] Desktop companion node (macOS/Linux/Windows)
- [x] Базовый PC peer service (Go) с режимом системного сервиса
- [ ] Синхронизация нескольких устройств одного пользователя
- [x] Web companion с ограниченным read-only режимом
- [ ] Плагинная транспортная архитектура (BLE-only/Wi-Fi-only/Hybrid)
- [ ] Публичный protocol spec и interoperability test suite
- [ ] Инструменты миграции базы и профиля между версиями
- [ ] Улучшенный CI/CD pipeline с матрицей устройств и sanity-check IPA
- [ ] Автоматизированные soak tests mesh-сети (длительные прогонны)
- [ ] Локализованный onboarding и встроенная справка
- [ ] Community governance: RFC-процесс и contribution guide

## Stage 9 — Trusted navigation & anti-spoof (v2.1)

- [x] Добавить `LocationTrustEngine` (CoreLocation + CoreMotion) с trust-score 0..100
- [x] Внедрить runtime-совместимость iOS 16+ для TrollStore и Developer Certificate сборок
- [x] Добавить базовый anti-spoof эвристический детект (simulated source / teleport / sensor mismatch)
- [x] Добавить UI-статус доверия геопозиции в настройках
- [x] Добавить сетевые cross-check сигналы (IP region / RTT consistency) в trust-score
- [ ] Добавить mesh consensus proximity check от соседних peer-ов
- [x] Добавить fallback на «последнюю доверенную точку» в навигационном маршруте
- [ ] Вынести веса trust-факторов в калибруемые profile-политики
- [ ] Добавить экран диагностики spoof-сигналов и confidence timeline
- [ ] Прогнать полевые тесты (город/трасса/офлайн) и откалибровать пороги

## Stage 10 — MeshWave major expansion (v2.2)

- [x] Ребрендинг приложения: MeshWave (название + отображение продукта)
- [x] Liquid Glass web UX в стиле desktop messenger (Telegram-like layout)
- [x] Live web event stream + secure diagnostics timeline
- [x] Криптографическое подтверждение web-сессии (`auth_challenge` + Ed25519 signature)
- [x] Показ fingerprint и peer identity в web-клиенте
- [x] PC peer service как системный сервис (Windows/macOS/Linux)
- [ ] Полноценный web-chat (send/read sync c iOS диалогами)
- [ ] Multi-device identity vault и синхронизация ключей между доверенными устройствами
- [ ] Mesh consensus для маршрутов/геопозиции от нескольких узлов
- [ ] Анонимные relay-пути с ротацией hop-профилей
