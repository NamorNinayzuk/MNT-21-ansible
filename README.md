# ДЗ 8.4 Работа с «Roles»

**Inventory** будет генерироваться динамически, поэтому соответствующий файл представлен только шаблоном групп, все остальное (разворачивание, настройка и уничтожение инфраструктуры) в скрипте: [go.sh](go.sh):

```yml
---
clickhouse:
  hosts:
vector:
  hosts:
lighthouse:
  hosts:
...
```
Проект состоит из 6 **play**:

1. Генерирование диманического **inventory**: `Generate dynamic inventory`
1. Добавление хостов в список известных: `Approve SSH fingerprint`
1. Установка **Clickhouse**: `Install Clickhouse` используя роль [ansible-clickhouse](https://github.com/NamorNinayzuk/ansible-clickhouse)
1. Установка **Vector**: `Install Vector` используя роль [vector-role](https://github.com/NamorNinayzuk/vector-role)
1. Установка **Lighthouse** включая **nginx**: `Install Lighthouse` используя роль [lighthouse-role](https://github.com/NamorNinayzuk/lighthouse-role)
1. Вывод IP адресов сервисов: `Echo instances hint`

## Генерирование диманического **inventory** `Generate dynamic inventory`

Для получения списка хостов используется интерфейс **Yandex.Cloud CLI**, а именно команда получения списка **instance** в формате **YAML**, который можно прочитать внутри **Ansible**

Команда получения хостов выглядит следующим образом: `yc compute instance list --format=yaml`, соответственно для её выполнения используется модуль `ansible.builtin.command`.
```yml
    - name: Get instances from Yandex.Cloud CLI
      ansible.builtin.command: "yc compute instance list --format=yaml"
      register: yc_instances
      failed_when: yc_instances.rc != 0
      changed_when: false
```
Её вывод регистрируется в переменную `yc_instances`.
Успешность определяется кодом возврата (`yc_instances.rc`).
Считается, что данный шаг может быть либо `ok`, либо `failed`

---

Преобразование вывода комманды **Yandex.Cloud CLI** в блок **YAML**
```yml
    - name: Set instances to facts
      ansible.builtin.set_fact:
        _yc_instances: "{{ yc_instances.stdout | from_yaml }}"
```
Результат фиксируется в фактах с именем `_yc_instances`

---

Для каждого элемента из `_yc_instance` выполняется добавление хоста в группу на основе имени машины (`group: "{{ item['name'] }}"`)
```yml
    - name: Add instances IP to hosts
      ansible.builtin.add_host:
        name: "{{ item['network_interfaces'][0]['primary_v4_address']['one_to_one_nat']['address'] }}"
        group: "{{ item['name'] }}"
        ansible_ssh_user: "admin"
      loop: "{{ _yc_instances }}"
      changed_when: false
```
При этом используется модуль `ansible.builtin.add_host` где в качестве группы передаётся название хоста. А также устанавливается пользователь (`ansible_ssh_user`) для подключения по SSH.
Считается, что шаг всегда завершается со статусом `ok`.

---

Последний шаг служит индикатором успеха формирования динамического **inventory** на основе числа полученных **instance**
```yml
    - name: Check instance count
      ansible.builtin.debug:
        msg: "Total instance count: {{ _yc_instances | length }}"
      failed_when: _yc_instances | length == 0
```

---

## Добавление хостов в список известных `Approve SSH fingerprint`

**Play** предназначен для автоматизации процесса добавления хостов в список известных без изменения настроек SSH клиентиа.
Следовательно, выполняется для всех имеющихся хостов.
Сбор артефактов всегда приводит к подключению к хостам, а значит для данного **play** его сбор нужно отключить (`gather_facts: false`)

Первый шаг выполняет запрос поиска отпечатка сервера в базе известных хостов командой `ssh-keygen -F <хост>`, где `<хост>` - IP адрес сервиса
```yml
    - name: Check known_hosts for
      ansible.builtin.command: ssh-keygen -F {{ inventory_hostname }}
      register: check_entry_in_known_hosts
      failed_when: false
      changed_when: false
      ignore_errors: true
      delegate_to: localhost
```
Команда должна быть выполнена на управляющей ноде, пожтому присутствует делегирование выполнения на **localhost** (опция `delegate_to:`).
Во избежания краха всего **playbook** при отсутствии отпечатка ошибки в данной **task** игнорируются (`ignore_errors: true`).
Также считается что команда всегда выполняется успешно (комбинация `failed_when: false` и `changed_when: false`).
Результат фиксируется в переменной `check_entry_in_known_hosts`

---

Если отпечатка хоста нет в списке известных, то команда `ssh-keygen -F` выполнится с кодом завершения `1`.
В этом случае нужно отключить запрос на добавление хоста в список известных добавив опцию `-o StrictHostKeyChecking=no` для клиента SSH.
Данные действия выполняются в следующей **task**
```yml
    - name: Skip question for adding host key
      ansible.builtin.set_fact:
        # StrictHostKeyChecking can be "accept-new"
        ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
      when: check_entry_in_known_hosts.rc == 1
```

---

Последнй шаг - запуск сбора артефактов с целью добавления хостов в список известных в ходе подключения к ним
```yml
    - name: Add SSH fingerprint to known host
      ansible.builtin.setup:
      when: check_entry_in_known_hosts.rc == 1
```

---

## Установка **Clickhouse**: `Install Clickhouse`

Используется роль [ansible-clickhouse](https://github.com/NamorNinayzuk/ansible-clickhouse) со следующими параметрами:

```yaml
---
clickhouse_version: "22.3.3.44"
clickhouse_listen_host:
  - "::"
clickhouse_dbs_custom:
  - { name: "logs" }
clickhouse_profiles_default:
  default:
    date_time_input_format: best_effort
clickhouse_users_custom:
  - { name: "user",
      password: "userlog",
      profile: "default",
      quota: "default",
      networks: { '::/0' },
      dbs: ["logs"],
      access_management: 0 }
file_log_structure: "file String, host String, message String, timestamp DateTime64"
...
```

Последний параметр (**file_log_structure**) используется в дополнительном шаге для создание таблицы. База `logs` создаётся ролью.

Создание таблицы используя клиент **clickhouse-client**.
```yaml
    - name: Create tables
      ansible.builtin.command: "clickhouse-client --host 127.0.0.1 -q 'CREATE TABLE logs.file_log ({{ file_log_structure }}) ENGINE = Log();'"
      register: create_tbl
      failed_when: create_tbl.rc != 0 and create_tbl.rc != 57
      changed_when: create_tbl.rc == 0
```
Успех определяется по коду возврата команды.
Успешное выполнение **SQL** команды (код `0`) говорит о том, что таблица отсутствовала и была успешно создана - статус `changed`.
Если таблица уже существовала, то код возврата будет равен `57` (определено опытным путём).
Любой другой код возврата автоматически говорит о какой-то ошибке СУБД.
Следовательно крах задачи должен включать оба последних условия, то есть `create_tbl.rc != 0` и `create_tbl.rc != 57`.

---

## Установка **Vector**: `Install Vector`

Используется роль [vector-role](https://github.com/NamorNinayzuk/vector-role) со следующими параметрами:

```yml
---
vector_test_dir: "/home/centos/test"
clickhouse_host: "{{ groups['clickhouse'][0] }}"
clickhouse_user: "user"
clickhouse_password: "userlog"
...
```

---

## Установка **Lighthouse** включая **nginx**: `Install Lighthouse`

Используется роль [lighthouse-role](https://github.com/NamorNinayzuk/lighthouse-role) со следующими параметрами:

```yml
---
lighthouse_path: "/usr/share/nginx/lighthouse"
clickhouse_host: "{{ groups['clickhouse'][0] }}"
clickhouse_user: "user"
clickhouse_password: "userlog"
...
```

---

## Вывод IP адресов сервисов: `Echo instances hint`

**Play** предназначен для упрощения понимания какой сервис на каком IP располагается.
Состоит из трёх одинаковых **task**, использующих модуль `ansible.builtin.debug` для вывода части переменных известных групп

```yaml
    - name: Clickhouse IP
      ansible.builtin.debug:
        msg: "Clickhouse IP: {{ groups['clickhouse'][0] }}"
    - name: Vector IP
      ansible.builtin.debug:
        msg: "Vector IP    : {{ groups['vector'][0] }}"
    - name: Lighthouse IP
      ansible.builtin.debug:
        msg: "Clickhouse IP: {{ groups['lighthouse'][0] }}"
```
