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
- Установка Fail2Ban и включение защиты SSH с автозапуском.
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

Fail2Ban защищает SSH на TCP-порту **22**: **5 неудачных попыток входа за 10 минут** приводят к блокировке доступа к SSH с этого IP на **24 часа**. Настройки записываются в `/etc/fail2ban/jail.d/99-remnanode-sshd.local`; существующий `jail.local` и настройки других служб сохраняются. Скрипт не создаёт правила Fail2Ban для Remnawave/Xray. Пункт **3** также включает эту защиту на ранее установленной ноде, а пункт **2** проверяет службу, автозапуск и jail `sshd` без изменений.

**Статус:** Beta.
