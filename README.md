# Data-Retriever

# ETL-пайплайн для сбора метрик рекламных креативов

Простой, но полнофункциональный **ETL-проект**, который автоматизирует сбор данных о производительности рекламных роликов из разрозненных источников (Google Drive и Google Sheets) и загружает их в централизованную облачную SQL-базу данных.

## 🚀 Проблема

Этот проект — архитектурное переосмысление (v2.0) реального рабочего пайплайна, который я изначально создал для автоматизации своих личных задач.

## v1.0: Решение реальной задачи

На моей текущей работе данные о производительности креативов хранятся в двух разных местах:

1.  **Метрики Hook/Hold:** Периодически выгружаются в виде скриншотов (изображений с текстом) в папку Google Drive.
2.  **Метрики тестов (CTR, CR, Installs и т.п.):**  Автоматически публикуются в общей Google-таблице.

Мне было необходимо сверяться с этими показателями, но процесс был крайне неэффективным: приходилось каждый раз вручную заходить в Google Drive, искать новые картинки, открывать их по-одному и параллельно искать данные по избранным роликам в *другой* таблице.

Я решил это автоматизировать. Ввиду ограничений доступа на рабочем аккаунте, я создал "полуавтоматическое" решение:

* Два скрипта в Google Colab: один считывал данные с картинок (OCR), второй — копировал данные из таблицы тестов. Все это выгружалось в мою личную сводную Google-таблицу. В качестве OCR решения сравнивались две open-source альтернативы (Tesseract и EasyOCR) и в итоге была выбрана EasyOCR в виду ничтожного количества ошибок. 
* (Дополнительно) Я также написал простой Google Apps Script, который раз в сутки проверял появление новых файлов и уведомлял меня в Telegram через чат-бота.


## v2.0: Портфолио (Этот репозиторий)

Решение v1.0 работало, но я понимал его ограничения: Google-таблица — это не база данных, она не гарантирует целостность данных и не защищает от дубликатов.

Для демонстрации Data Engineering подхода я создал этот проект:
1.  **Фейковые данные:** Я создал полный аналог "боевых" данных на своем личном аккаунте.
2.  **SQL-база:** Я переписал пайплайны для загрузки данных в облачную PostgreSQL (на Neon).
3.  **Два независимых ETL-пайплайна:** выполняются в среде Google Colab и загружают данные облачную базу данных.

### Пайплайн 1: OCR (Из Google Drive)

* **Extract:** Скрипт сканирует папки Google Drive (примонтированные к Colab), отслеживая уже обработанные даты.
* **Transform:**
    1.  Изображения обрезаются до области, где сосредоточена нужная текстовая информация (`cv2`).
    2.  Текст распознается с помощью EasyOCR.
    3.  Имена проектов и креативов парсятся из имени файла.
    4.  Метрики `Hook` и `Hold` извлекаются из текста с помощью `regex`.
* **Load:** Данные загружаются в таблицу `hook_hold_metrics` в PostgreSQL с использованием `UPSERT`.

### Пайплайн 2: GSheets (Из Google-таблиц)

* **Extract:** Скрипт подключается к Google Sheets API (через Service Account), автоматически определяет имя проекта по названию листа и запрашивает у SQL-базы последнюю загруженную дату.
* **Transform:**
    1.  Загружаются только *новые* строки (по дате).
    2.  Данные проходят валидацию и очистку (например, `"-"` в `bench` заменяется на `NULL`).
    3.  Строки приводятся к правильным типам данных (`Integer`, `Float`).
* **Load:** Данные загружаются в таблицу `auto_test_metrics` с использованием `UPSERT` по составному ключу (`video_id`, `date`, `team`).


## 🗄️ Модель данных и Схема (Data Model and Schema)

Важной частью проекта было проектирование реляционной схемы данных (ERD) для обеспечения целостности (FOREIGN KEY) и предотвращения дубликатов (UNIQUE).

Полный код для создания таблиц находится в файле schema.sql. Ниже представлена логическая структура данных, реализованная в PostgreSQL:

```sql
/* * 1. Справочник Игр / Проектов
 * Хранит "GHM", "GHM-2" и т.д.
 */
CREATE TABLE projects (
	id SERIAL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	created_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE projects IS 'Справочник проектов';


/* * 2. Справочник Креативов / Роликов
 * Хранит уникальные имена роликов.
 */
CREATE TABLE creatives (
	video_id SERIAL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	project_id INTEGER NOT NULL,
	created_at TIMESTAMP DEFAULT NOW(),
	-- Гарантирует, что имя ролика уникально ВНУТРИ проекта
	UNIQUE (project_id, name), 
	-- Связь: Если удалить проект, удалятся и все его ролики
	FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

COMMENT ON TABLE creatives IS 'Справочник уникальных креативов (роликов)';
CREATE INDEX idx_creatives_project_id ON creatives(project_id); -- <-- Индекс для JOIN


/* * 3. Журнал Hook/Hold метрик (из OCR)
 */
CREATE TABLE hook_hold_metrics (
	id SERIAL PRIMARY KEY,
	video_id INTEGER NOT NULL,
	hook FLOAT,
	hold FLOAT,
	date DATE NOT NULL,
	created_at TIMESTAMP DEFAULT NOW(),
	
	-- Гарантирует, что у ролика не будет двух записей за один день
	UNIQUE (video_id, date), 
	-- Связь: Если удалить ролик, удалятся и все его метрики
	FOREIGN KEY (video_id) REFERENCES creatives(video_id) ON DELETE CASCADE
);

COMMENT ON TABLE hook_hold_metrics IS 'Метрики Hook/Hold креативов (видео)';
-- Индексы для JOIN'ов и фильтров
CREATE INDEX idx_hh_video_id ON hook_hold_metrics(video_id);
CREATE INDEX idx_hh_date ON hook_hold_metrics(date);
CREATE INDEX idx_hh_hook ON hook_hold_metrics(hook);


/* * 4. Журнал метрик из Автотестов (из GSheet)
 *
 */
CREATE TABLE auto_test_metrics (
	id SERIAL PRIMARY KEY,
	video_id INTEGER NOT NULL,
	date DATE NOT NULL,
	team TEXT NOT NULL,
	bench FLOAT,
	retention FLOAT,
	clicks INT,
	installs INT,
	ctr FLOAT,
	cr FLOAT,
	created_at TIMESTAMP DEFAULT NOW(),

	-- Гарантирует, что у ролика не будет двух записей за день ОТ ОДНОЙ КОМАНДЫ
	UNIQUE (video_id, date, team), 
	-- Связь: Если удалить ролик, удалятся и эти метрики
	FOREIGN KEY (video_id) REFERENCES creatives(video_id) ON DELETE CASCADE
);

COMMENT ON TABLE auto_test_metrics IS 'Метрики из таблицы автотестов';
-- Индексы для JOIN'оv и фильтров
CREATE INDEX idx_test_video_id ON auto_test_metrics(video_id);
CREATE INDEX idx_test_date ON auto_test_metrics(date);
);
```


## 🏆 Доказательство выполнения и Результаты

Данные, собранные обоими пайплайнами, хранятся в облачной PostgreSQL. Ниже представлены скриншоты, подтверждающие успешное выполнение ETL-процесса и корректность связей в модели данных.

### A. Статус загрузки (Счетчик)

Проверка, что данные присутствуют во всех ключевых таблицах:
```sql
SELECT
    (SELECT COUNT(*) FROM projects) AS total_projects,
    (SELECT COUNT(*) FROM creatives) AS total_creatives,
    (SELECT COUNT(*) FROM hook_hold_metrics) AS total_hook_hold_metrics,
    (SELECT COUNT(*) FROM auto_test_metrics) AS total_auto_test_metrics;
```

<img width="1112" height="312" alt="Image" src="https://github.com/user-attachments/assets/68414636-d37f-4eea-99ae-3675785bb12f" />

### B. Демонстрация связанных данных (Автотесты)

Пример запроса, который выводит метрики, связывая их с именами креатива и проекта:

```sql
SELECT
    p.name AS project_name,
    c.name AS creative_name,
    atm.date,
    atm.team,
    atm.bench,
    atm.installs,
    atm.ctr
FROM auto_test_metrics atm
JOIN creatives c ON atm.video_id = c.video_id
JOIN projects p ON c.project_id = p.id
LIMIT 5;
```
<img width="1192" height="583" alt="Image" src="https://github.com/user-attachments/assets/683efc31-8bea-485d-9acd-a62b9d018c15" />

## ⚙️ Настройка и запуск

Для запуска ETL-пайплайна необходима настройка облачных сервисов Google и базы данных Neon.

### 1. Подготовка облачных ключей (Google Cloud / Neon)

1.  **Neon Connection String:** Получите `DATABASE_URL` из вашего дашборда Neon.
2.  **Google Service Account:**
    * Создайте Service Account в Google Cloud Platform (GCP).
    * Включите **Google Sheets API** и **Google Drive API**.
    * Скачайте **JSON-ключ** (`credentials.json`).

3.  **Конфигурация в Google Colab:**
    * Откройте **"Секреты"** (иконка "ключ" на боковой панели Colab).
    * Добавьте два секрета:
        * `DATABASE_URL`: Полная строка подключения к Neon.
        * `GOOGLE_CREDS_JSON`: Полное содержимое вашего JSON-ключа (для доступа к Google Sheets API).

### 2. Источники данных

Для запуска проекта сделайте следующее:

1.  **Скопируйте фейковую папку Drive:** Перейдите по ссылке на папку OCR (ниже) и скопируйте ее **себе** в Google Drive.
2.  **Скопируйте фейковую таблицу и дайте права:** Поделитесь (права Читателя) фейковой Google Таблицей (ссылка ниже) **с `client_email` из JSON-ключа.**

* **Google Sheets (Автотесты):** https://docs.google.com/spreadsheets/d/198x3oQ9jPlRaWf2l3gzr9PsAGr68dhfPj2a7K4V9q5g/edit?usp=sharing
* **Google Drive (Картинки/OCR):** https://drive.google.com/drive/folders/1-Eh3D3AGfikeM8v1S-JCjyxFd1-8_Jx1?usp=sharing

### 3. Порядок выполнения ETL-пайплайна

1.  **Монтирование Google Drive:**
    * Откройте `SQL_pipeline.ipynb`. **Сначала** примонтируйте ваш Google Drive (кнопкой в Colab).
    * Убедитесь, что `root_folder` в коде указывает на **правильный путь** к скопированной папке на вашем примонтированном диске.
    * Нажмите **"Среда выполнения" -> "Выполнить все"**.
    * Также скрипты можно вызывать по отдельности

## 💻 Технологии

* **Язык:** Python
* **Среда выполнения:** Google Colab
* **База данных:** **PostgreSQL** (в облаке **Neon**)
* **ETL-библиотеки:** **SQLAlchemy** (для ORM и безопасных `UPSERT`-ов), `gspread` (для Google Sheets API), `opencv-python` (для обработки изображений), `EasyOCR` (для распознавания текста).
* **Ключевые навыки:** Проектирование ETL-пайплайнов, **моделирование данных** (Data Modeling), работа с облачными БД, `UPSERT`-логика.

---

## 📂 Структура репозитория
<img width="679" height="125" alt="Image" src="https://github.com/user-attachments/assets/cda6e0e5-a1e8-4279-98b2-af22a574ed1c" />


## 📈 Планы по развитию (v2.1): Полная автоматизация

Текущая архитектура v2.0 использует Google Colab для простоты демонстрации и быстрой итерации. Следующие шаги — это перевод проекта из "полуавтоматического" режима (ручной запуск в Colab) в полностью автоматизированный пайплайн.

### 1. Переход на Serverless-функции

* **Проблема:** Скрипты `.ipynb` требуют ручного запуска в интерактивной среде Colab.
* **Решение:** Перенести код из ноутбуков `.ipynb` в чистые `.py` скрипты. Развернуть каждый пайплайн как отдельную **Google Cloud Function**. 

### 2. Аутентификация через Service Account для Google Drive

* **Проблема:** Пайплайн OCR (№1) все еще требует ручного "монтирования" Google Drive в Colab. Это главный "ручной" шаг.
* **Решение:** Полностью перейти на **Google Drive API** (вместо `os.walk()`). Использовать тот же **Service Account** (JSON-ключ), который уже используется для Google Sheets. Это позволит скрипту программно "видеть" новые файлы, скачивать их во временную память функции, обрабатывать и удалять, не требуя никакого ручного вмешательства.

### 3. Запуск по расписанию

* **Проблема:** Ручной запуск.
* **Решение:** Использовать **Google Cloud Scheduler** для автоматического вызова обеих Google Cloud Functions по расписанию (например, раз в сутки в 3 часа ночи). Это полностью уберет человека из цикла.

### 4. API для данных 

* **Проблема:** Данные очищены и лежат в SQL-базе, но к ним нет удобного доступа для других систем (например, BI-дашбордов или других сервисов).
* **Решение:** Создать простой **API на FastAPI**, который будет читать данные напрямую из облачной PostgreSQL (Neon) и отдавать их в формате JSON. Этот API также можно развернуть на "serverless" платформе (например, **Google Cloud Run**). Это позволит легко строить дашборды в Metabase, Power BI или Grafana.
