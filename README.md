<p align="center">
  <img src="banner.png" alt="Remnawave Node Manager" width="100%">
</p>

# Remnawave Node Manager

Установка и проверка RemnaNode для **Ubuntu 24.04 LTS**.

**v0.2.9 · Beta**

## Запуск

Запускайте от **root** в интерактивном терминале:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dimastrum/Remnawave-node-manager/main/install-v0.2.9.sh)
```

Понадобятся **SECRET_KEY** и публичный **IPv4 панели**.

## Меню

| Пункт | Действие |
|:---:|---|
| 1 | Установить ноду |
| 2 | Проверить без изменений |
| 3 | Продолжить установку после сбоя |
| 0 | Выход |

## Что настраивается

- Docker, Compose и RemnaNode.
- UFW до запуска ноды: TCP **22, 80, 443**; **2222** — разрешение для IP панели.
- Fail2Ban для SSH: **5 ошибок за 10 минут → бан на 24 часа**.
- Блокировка входящего Ping IPv4.
- Logrotate для файлов `/var/log/remnanode/*.log`.

Меню показывает текущие статусы. Итоговый отчёт — результаты всех **9 шагов**.

> Запись логов Xray включите в профиле панели.
>
> Блокировка ICMP может мешать диагностике и PMTU Discovery.
