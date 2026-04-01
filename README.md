# MTG Panel — Web Management Dashboard

Современная веб-панель для управления MTProto прокси-сервером [mtg](https://github.com/9seconds/mtg).

## Установка одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/mtg-panel/main/install.sh)
```

> Замените `YOUR_USERNAME` на ваш логин GitHub.

## Что умеет панель

- 📊 **Дашборд** — статус прокси, нагрузка CPU и RAM в реальном времени
- ⚙️ **Конфигурация** — смена порта и домена маскировки (Fake-TLS) без терминала  
- 🔑 **Генерация ключей** — автоматический `mtg generate-secret`
- 📋 **Telegram ссылка** — готовая `tg://proxy?...` ссылка в один клик
- 📜 **Живые логи** — последние 50 строк `journalctl` с авто-обновлением
- 🛡️ **Проверка портов** — проверяет, не занят ли порт перед применением
- 🌐 **Готовые домены** — выпадающий список проверенных доменов для маскировки
- ⬆️ **Авто-обновление** — скачать последнюю версию mtg прямо из панели
- 🔒 **Авторизация** — вход только по логину и паролю

## Структура файлов

```
mtg-panel/
├── app.py              # FastAPI бэкенд
├── index.html          # Фронтенд (Tailwind CSS, тёмный дизайн)
├── requirements.txt    # Python зависимости
├── mtp-panel.service   # Systemd unit файл (справочный)
├── install.sh          # Установщик
└── README.md
```

## Требования

- Ubuntu / Debian / CentOS (Linux)
- Python 3.8+
- Root доступ (для управления systemd)

## Порты

| Служба    | Порт | Описание                  |
|-----------|------|---------------------------|
| mtp-panel | 8888 | Веб-панель управления     |
| mtg       | 8443 | MTProto прокси (по умолч.)|

## Данные по умолчанию

- **URL:** `http://ВАШ_IP:8888`
- **Логин:** `Fastg`
- **Пароль:** `Mjmzxcmjm123`

## Управление службами

```bash
# Статус
systemctl status mtp-panel
systemctl status mtg

# Перезапуск
systemctl restart mtp-panel
systemctl restart mtg

# Логи
journalctl -u mtp-panel -f
journalctl -u mtg -f
```
