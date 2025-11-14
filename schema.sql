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
 * (Исправлена опечатка 'mertics' -> 'metrics')
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