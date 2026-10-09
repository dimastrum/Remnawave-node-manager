<p align="center">
  <img src="banner.png" alt="Remnawave Node Manager" width="100%">
</p>

# Remnawave Node Manager

Автоматизированный Bash-установщик и аудитор RemnaNode для **Ubuntu 24.04 LTS**.

**Версия:** v0.2.9 (Beta)

### 🚀 Возможности

- Установка Docker, Docker Compose и RemnaNode.
- Подключение ноды к панели Remnawave.
- Настройка UFW, ICMP и Logrotate.
- Отключение автоматических блокировок Fail2Ban.
- Проверка состояния ноды и подключений.

### 📦 Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dimastrum/Remnawave-node-manager/main/install-v0.2.9.sh)
```

### ⚙️ Меню

**1** — Установить новую RemnaNode  
**2** — Проверить существующую ноду (без изменений)  
**3** — Завершить незавершённую установку

Для установки потребуются **SECRET_KEY** из Remnawave и публичный **IPv4 панели**.

**Статус:** Beta.
