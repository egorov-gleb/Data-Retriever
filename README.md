# Data-Retriever

# ETL-пайплайн для сбора метрик рекламных креативов

Простой, но полнофункциональный **ETL-проект**, который автоматизирует сбор данных о производительности рекламных роликов из разрозненных источников (Google Drive и Google Sheets) и загружает их в централизованную облачную SQL-базу данных.

## 🚀 Проблема

Этот проект — архитектурное переосмысление (v2.0) реального рабочего пайплайна, который я изначально создал для автоматизации своих личных задач.

## v1.0: Решение реальной задачи

Проект вырос из реальной рабочей потребности.

Метрики рекламных креативов хранились в двух независимых источниках:
- скриншоты отчётов в Google Drive
- таблица автотестов в Google Sheets

Для анализа эффективности приходилось вручную:
- искать новые изображения,
- извлекать показатели,
- сверять их с данными из таблицы.

Такой процесс был не масштабируемым, не гарантировал целостности данных и не защищал от дубликатов.

В ответ на это была спроектирована система полу-втоматизированной загрузки данных (ввиду ограничений доступа на рабочем аккаунте) в централизованную PostgreSQL-базу:

* Два скрипта в Google Colab: один считывал данные с картинок (OCR), второй — копировал данные из таблицы тестов. Все это выгружалось в мою личную сводную Google-таблицу. В качестве OCR решения сравнивались две open-source альтернативы (Tesseract и EasyOCR) и в итоге была выбрана EasyOCR в виду ничтожного количества ошибок. 

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
 * Хранит "TR", "HG" и т.д.
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
	name TEXT NOT NULL,
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
	hook DOUBLE PRECISION,
	hold DOUBLE PRECISION,
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
	bench INT,
	retention DOUBLE PRECISION,
	clicks INT,
	installs INT,
	impressions INT,
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


```
### Принципы хранения метрик

В базе хранятся только атомарные (базовые) показатели: показы, клики, установки и т.д.

Композитные метрики (например, CTR, CR и другие производные коэффициенты) 
не сохраняются в таблицах намеренно, так как они могут быть детерминированно вычислены 
на уровне SQL-запросов или BI-инструментов.

Такой подход:
- исключает избыточность данных
- предотвращает рассинхронизацию значений
- упрощает поддержку схемы


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
    atm.retention
FROM auto_test_metrics atm
JOIN creatives c ON atm.video_id = c.video_id
JOIN projects p ON c.project_id = p.id
LIMIT 5;
```
<img width="1213" height="581" alt="Снимок экрана 2026-02-16 в 22 07 42" src="https://github.com/user-attachments/assets/d31d8b26-2a93-4ffe-9270-ce8cbef958c7" />


## 📊 Дашборд: динамика ключевых метрик автотестов

В рамках проекта реализован интерактивный BI-дашборд в Metabase, отражающий динамику основных показателей эффективности креативов на основе данных автотестов.

### 📈 Основные визуализации

#### 1️⃣ Clicks Trend

Линейный график суммарного количества кликов по дням.

* Агрегация: `SUM(clicks)`
* Группировка: по дате
* Назначение: анализ динамики вовлечённости и выявление аномалий трафика
<img width="1262" height="684" alt="Снимок экрана 2026-02-17 в 15 20 11" src="https://github.com/user-attachments/assets/0ded7bb8-de9d-4bbe-a350-58839ee14b62" />
---

#### 2️⃣ Installs Trend

Линейный график суммарного количества установок по дням.

* Агрегация: `SUM(installs)`
* Группировка: по дате
* Назначение: оценка эффективности креативов и анализа конверсии в установки
<img width="1258" height="680" alt="Снимок экрана 2026-02-17 в 15 21 34" src="https://github.com/user-attachments/assets/8e79985f-a8c0-4c2d-9dc6-db3767d52f2f" />

---

#### 3️⃣ CTR Trend

Линейный график динамики CTR.

Формула расчёта:

```sql
CTR = SUM(clicks) / SUM(impressions)
```

* Метрика рассчитывается на уровне агрегированных данных
* Исключено усреднение по строкам
* Отображается в процентном формате

Назначение: оценка кликабельности креативов.
<img width="1251" height="688" alt="Снимок экрана 2026-02-17 в 15 22 11" src="https://github.com/user-attachments/assets/6470e14d-b777-437e-905d-8165f0439d65" />

---

#### 4️⃣ IR Trend

Линейный график динамики IR (Install Rate).

Формула расчёта:

```sql
IR = SUM(installs) / SUM(impressions)
```

* Рассчитывается на агрегированном уровне
* Отображается в процентном формате

Назначение: анализ полной конверсии показов в установки.
<img width="1255" height="685" alt="Снимок экрана 2026-02-17 в 15 22 35" src="https://github.com/user-attachments/assets/9cfcedeb-9867-4d22-bb56-d7687106d11c" />

---

### 🎛 Возможности дашборда

* Фильтрация по диапазону дат
* Фильтрация по команде (`team`)
* Использование композитных метрик (CTR, IR)
<img width="1065" height="665" alt="Снимок экрана 2026-02-17 в 15 23 12" src="https://github.com/user-attachments/assets/717a79bf-a48c-49a0-8c5e-033347d9071d" />

---


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
    * Убедитесь, что `root_folder` в Config указывает на **правильный путь** к скопированной папке на вашем примонтированном диске.
    * Нажмите **"Среда выполнения" -> "Выполнить все"**.
    * Также скрипты можно вызывать по отдельности

## 💻 Технологии

* **Язык:** Python
* **Среда выполнения:** Google Colab
* **База данных:** PostgreSQL 
* **ETL-библиотеки:** SQLAlchemy, `gspread`, `opencv-python`, `EasyOCR`.
* **Ключевые навыки:** Проектирование ETL-пайплайнов, моделирование данных, работа с облачными БД.

---

## 📂 Структура репозитория
<img width="679" height="125" alt="Image" src="https://github.com/user-attachments/assets/cda6e0e5-a1e8-4279-98b2-af22a574ed1c" />


## 📈 Планы по развитию (v2.1): Полная автоматизация

Текущая архитектура v2.0 использует Google Colab для простоты демонстрации и быстрой итерации. Следующие шаги — это перевод проекта из "полуавтоматического" режима (ручной запуск в Colab) в полностью автоматизированный пайплайн.

### 1. Переход на Serverless-функции

* **Проблема:** Скрипт `.ipynb` требует ручного запуска в интерактивной среде Colab.
* **Решение:** Перенести код из ноутбука `.ipynb` в чистые `.py` скрипты. Развернуть каждый пайплайн как отдельную **Google Cloud Function**. 

### 2. Аутентификация через Service Account для Google Drive

* **Проблема:** Пайплайн все еще требует ручного "монтирования" Google Drive в Colab. Это главный "ручной" шаг.
* **Решение:** Полностью перейти на **Google Drive API** (вместо `os.walk()`). Использовать тот же **Service Account** (JSON-ключ), который уже используется для Google Sheets. Это позволит скрипту программно "видеть" новые файлы, скачивать их во временную память функции, обрабатывать и удалять, не требуя никакого ручного вмешательства.

### 3. Запуск по расписанию

* **Проблема:** Ручной запуск.
* **Решение:** Использовать **Google Cloud Scheduler** для автоматического вызова обеих Google Cloud Functions по расписанию (например, раз в сутки в 3 часа ночи). Это полностью уберет человека из цикла.

### 4. API для данных 

* **Проблема:** Данные очищены и лежат в SQL-базе, но к ним нет удобного доступа для других систем (например, BI-дашбордов или других сервисов).
* **Решение:** Создать простой **API на FastAPI**, который будет читать данные напрямую из облачной PostgreSQL (Neon) и отдавать их в формате JSON. Этот API также можно развернуть на "serverless" платформе (например, **Google Cloud Run**). Это позволит легко строить дашборды в Metabase, Power BI или Grafana.
