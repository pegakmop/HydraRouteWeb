Установить/переустановить/обновить:
```
curl -L -s "https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/refs/heads/main/webpanel/install.sh" > /opt/tmp/install.sh && chmod +x /opt/tmp/install.sh && /opt/tmp/install.sh
```
**Только панель, без скрипта HydraRoute**.

Управление панелью (терминал entware):
```
/opt/etc/init.d/S99hpanel restart
```
Доступные команды: `start|stop|restart|check|status|kill`
