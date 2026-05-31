# Roadmap

## MVP stabilization (текущий этап)

- [x] P2P discovery
- [x] Личный чат
- [x] Базовый relay
- [x] SQLite storage
- [x] Автообновления из GitHub Releases
- [ ] Дожать стабильность звонков под длительную нагрузку
- [ ] Улучшить дедупликацию/очистку истории в edge-cases

## v1.3

- [ ] Групповые чаты (базовая модель участников)
- [ ] Улучшенный UI статусов доставки (queued/sent/delivered/read)
- [ ] Экспорт/импорт локального профиля и истории
- [ ] Улучшенный экран топологии сети (маршруты + latency)

## v1.4

- [ ] Полноценный file transfer resume после разрыва
- [ ] Параллельная загрузка чанков
- [ ] Контроль целостности и автоматический repair/re-request чанков
- [ ] Ограничения bandwidth / QoS профили

## v1.5

- [ ] Групповые ключи и ротация ключей для групп
- [ ] Улучшенный DHT peer discovery (Kademlia tuning)
- [ ] NAT traversal improvements
- [ ] Расширенная диагностика и crash telemetry (локальная, без сервера)

## Дальше

- [ ] Видео-звонки
- [ ] Screen sharing
- [ ] Плагины транспорта (BLE-only / Wi-Fi-only / Hybrid policy)
- [ ] Desktop companion node
