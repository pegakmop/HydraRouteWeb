#!/bin/sh

# Функция анимации загрузки
loading_animation() {
  local pid=$1
  local message=$2
  local spin='-\|/'

  echo -n "$message... "

  while kill -0 $pid 2>/dev/null; do
    for i in $(seq 0 3); do
      echo -ne "\b${spin:$i:1}"
      usleep 100000  # 0.1 сек
    done
  done

  echo -e "\b✔ Готово!"
}

# Получение доступного места на разделе /opt
AVAILABLE_SPACE=$(df /opt | awk 'NR==2 {print $4}')

# Проверка, если места меньше 120MB
if [ "$AVAILABLE_SPACE" -lt 122880 ]; then
  echo "Ошибка: недостаточно места для установки."
  exit 1
fi

# Проверка наличия пакета node
if ! opkg list-installed | grep -q "^node -"; then
  echo "Node.js не найден. Устанавливаю..."

  # Обновление списка пакетов
  opkg update >/dev/null 2>&1

  # Запуск установки в фоне
  opkg install node >/dev/null 2>&1 &

  # Запуск анимации во время установки
  loading_animation $! "Установка Node.js"
else
  echo "Node.js уже установлен."
fi

# Создание директории /opt/tmp, если она не существует
mkdir -p /opt/tmp

# На всякий случай
echo "Контрольный..."
/opt/etc/init.d/S99hpanel kill >/dev/null 2>&1
chmod -R 777 /opt/etc/HydraRoute/ >/dev/null 2>&1
chmod 777 /opt/etc/init.d/S99hpanel >/dev/null 2>&1
rm -rf /opt/etc/HydraRoute/ >/dev/null 2>&1
rm -r /opt/etc/init.d/S99hpanel >/dev/null 2>&1

# Скачивание архива в фоне
curl -L -o /opt/tmp/hpanel.tar "https://github.com/Ground-Zerro/HydraRoute/raw/refs/heads/main/webpanel/hpanel.tar" >/dev/null 2>&1 &

# Запуск анимации во время загрузки
loading_animation $! "Загрузка архива hpanel"

# Создание директории /opt/etc/HydraRoute, если ее не существует
mkdir -p /opt/etc/HydraRoute

# Запуск распаковки в фоне
tar -xf /opt/tmp/hpanel.tar -C /opt/etc/HydraRoute/ &

# Запуск анимации во время распаковки
loading_animation $! "Распаковка hpanel"

# Удаление архива
rm /opt/tmp/hpanel.tar

# Перемещение файла в init.d
mv /opt/etc/HydraRoute/S99hpanel /opt/etc/init.d/S99hpanel

# Установка прав
echo "Установка необходимых прав на файлы и папки..."
chmod -R 444 /opt/etc/HydraRoute/
chmod 755 /opt/etc/init.d/S99hpanel
chmod 755 /opt/etc/HydraRoute/hpanel.js

# Запуск сервиса
echo "Запуск панели..."
/opt/etc/init.d/S99hpanel start

# Получение IP-адреса роутера
IP_ADDRESS=$(ip addr show br0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

# Информационные сообщения
echo ""
echo "Установка завершена."
echo ""
echo "Панель управления HydraRoute доступна по адресу: http://$IP_ADDRESS:2000/"
echo ""

rm -- "$0"
